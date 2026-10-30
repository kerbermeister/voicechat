"""Install the tested dependency profile on a clean Debian 12 amd64 node.

This is package preparation, not role deployment. Existing Docker installations
need explicit adoption elsewhere. Completed repeats inspect versions only; an
interrupted apt transaction resumes only its recorded package closure.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import urllib.request

import host_preflight
import managed_state
import network_bootstrap
import node_inventory
import role_release
import topology
from tunnel_config import physical_nodes

BASE = {
    'ca-certificates': '20250419~deb12u2',
    'iproute2': '6.1.0-3',
    'nftables': '1.0.6-2+deb12u2',
    'openssl': '3.0.22-1~deb12u2',
    'wireguard-tools': '1.0.20210914-1+b1',
}
DOCKER = {
    'docker-ce': '5:29.8.1-1~debian.12~bookworm',
    'docker-ce-cli': '5:29.8.1-1~debian.12~bookworm',
    'containerd.io': '2.4.2-3~debian.12~bookworm',
    'docker-compose-plugin': '5.5.1-1~debian.12~bookworm',
}
KEY_URL = 'https://download.docker.com/linux/debian/gpg'
KEY_SHA = '1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570'
KEY_PATH = 'etc/apt/keyrings/voicechat-docker.asc'
SOURCE_PATH = 'etc/apt/sources.list.d/voicechat-docker.sources'
SOURCE = b'''Types: deb
URIs: https://download.docker.com/linux/debian
Suites: bookworm
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/voicechat-docker.asc
'''
PACKAGE = re.compile(r'[a-z0-9][a-z0-9+.-]*(?::amd64)?')


def command(arguments):
    result = subprocess.run(arguments, capture_output=True, timeout=1800,
                            env={**os.environ, 'DEBIAN_FRONTEND': 'noninteractive'})
    if result.returncode:
        raise RuntimeError('Host package operation failed; preserve its journal and inspect apt logs')
    if len(result.stdout) > 1024 * 1024:
        raise ValueError('Package inspection output exceeds its bound')
    return result.stdout.decode()


def binding(inventory, node):
    node_inventory.validate(inventory)
    nodes = physical_nodes(inventory)
    if node not in nodes:
        raise ValueError('Select one physical node from the verified inventory')
    return {'schema': 1, 'service_id': inventory['service_id'], 'node': node,
            'assignment': nodes[node],
            'profile': role_release.json_digest({'base': BASE, 'docker': DOCKER,
                                                'key_sha256': KEY_SHA, 'source': SOURCE.decode()})}


def package_rows(run):
    rows = {}
    for line in run(['dpkg-query', '-W', '-f=${binary:Package}\t${db:Status-Abbrev}\t${Version}\n']).splitlines():
        parts = line.split('\t')
        if len(parts) != 3 or not PACKAGE.fullmatch(parts[0]) or len(parts[1]) != 3:
            raise ValueError('Unexpected dpkg database response')
        name, status, version = parts
        if name in rows:
            raise ValueError('Duplicate package database entry')
        rows[name] = (status, version)
    return rows


def unfinished(rows):
    # dpkg can retain removed-package configuration (rc); it is not unfinished.
    return {name for name, (status, _) in rows.items()
            if status[1] in 'UFWtH' or status[2] != ' '}


def closure(output, requested):
    names = set(requested)
    for line in output.splitlines():
        if line.startswith('Remv '):
            raise ValueError('Dependency installation must not remove packages')
        if line.startswith(('Inst ', 'Conf ')):
            parts = line.split()
            if len(parts) < 2 or not PACKAGE.fullmatch(parts[1]):
                raise ValueError('Unexpected apt simulation response')
            names.add(parts[1])
    if len(names) > 256:
        raise ValueError('Unexpectedly broad package transaction')
    return sorted(names)


def fetch_key():
    with urllib.request.urlopen(KEY_URL, timeout=30) as response:
        # Never follow a signing-key redirect to a different authority.
        if response.geturl() != KEY_URL:
            raise ValueError('Unexpected Docker signing-key redirect')
        raw = response.read(16385)
    if len(raw) > 16384 or hashlib.sha256(raw).hexdigest() != KEY_SHA:
        raise ValueError('Docker signing key differs from the reviewed profile')
    return raw


def check_sources(system_root):
    source_dir = network_bootstrap.directory(system_root, 'etc/apt/sources.list.d')
    paths = [system_root / 'etc/apt/sources.list']
    if source_dir.exists():
        paths.extend(source_dir.iterdir())
    for path in paths:
        if path.name == Path(SOURCE_PATH).name:
            if network_bootstrap.existing(path) not in (None, SOURCE):
                raise ValueError('Owned Docker repository configuration changed')
        elif path.suffix in ('.list', '.sources') or path.name == 'sources.list':
            data = network_bootstrap.existing(path)
            if data is not None and b'download.docker.com' in data:
                raise ValueError('Existing Docker repository requires explicit adoption')
    key = network_bootstrap.existing(system_root / KEY_PATH)
    if key is not None and hashlib.sha256(key).hexdigest() != KEY_SHA:
        raise ValueError('Owned Docker signing key changed')


def inspect_identity(system_root, expected):
    host = network_bootstrap.existing(system_root / 'etc/ssh/ssh_host_ed25519_key.pub')
    if host is None or ' '.join(host.decode().split()[:2]) != expected['assignment']['ssh_host_key']:
        raise ValueError('Package preparation belongs to another SSH host')
    release = platform.freedesktop_os_release()
    if (platform.system(), platform.machine(), release.get('ID'), release.get('VERSION_ID')) != (
            'Linux', 'x86_64', 'debian', '12'):
        raise ValueError('The tested clean-host package profile requires Debian 12 amd64')


def verify_versions(rows):
    for name, version in {**BASE, **DOCKER}.items():
        if rows.get(name) != ('ii ', version):
            raise ValueError('Installed dependency differs from the tested profile: ' + name)
    if unfinished(rows):
        raise ValueError('Finish the outstanding dpkg transaction before using the host')


def journal_for(path, expected):
    journal = managed_state.read(path)
    topology.fields(journal, ('target', 'phase', 'packages'))
    if (journal['target'] != expected or journal['phase'] not in ('base', 'docker', 'verify') or
            not isinstance(journal['packages'], list) or len(journal['packages']) > 256 or
            any(not isinstance(name, str) or not PACKAGE.fullmatch(name) for name in journal['packages']) or
            journal['packages'] != sorted(set(journal['packages'])) or
            (journal['phase'] == 'verify' and journal['packages'])):
        raise ValueError('Resume the same owned package transaction')
    return journal


def verify_runtime(system_root, run):
    key = network_bootstrap.existing(system_root / KEY_PATH)
    if (key is None or hashlib.sha256(key).hexdigest() != KEY_SHA or
            network_bootstrap.existing(system_root / SOURCE_PATH) != SOURCE):
        raise ValueError('Installed Docker repository profile is incomplete')
    if run(['docker', 'info', '--format', '{{.DockerRootDir}}']).strip() != '/var/lib/docker':
        raise ValueError('Clean-host profile requires the default rootful Docker store')
    if 'rootless' in run(['docker', 'info', '--format', '{{json .SecurityOptions}}']):
        raise ValueError('Clean-host profile requires rootful Docker')


def clear_pending(path):
    path.unlink()
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def install(directory, inventory, node, *, system_root=Path('/'), run=command,
            collect=host_preflight.collect, download=fetch_key):
    system_root = Path(system_root).absolute()
    expected = binding(inventory, node)
    inspect_identity(system_root, expected)
    check_sources(system_root)
    with managed_state.locked(directory) as state:
        current, pending = state / 'current.json', state / 'pending.json'
        journal = journal_for(pending, expected) if pending.exists() or pending.is_symlink() else None
        if current.exists() or current.is_symlink():
            if managed_state.read(current) != expected:
                raise ValueError('Host preparation identity/profile changed; use an explicit upgrade')
            if journal is not None and journal['phase'] != 'verify':
                raise ValueError('Unexpected unfinished transaction after host preparation')
            verify_versions(package_rows(run))
            verify_runtime(system_root, run)
            if journal is not None:
                clear_pending(pending)
            return expected
        # The pinned nftables package does not start a newly installed unit,
        # but upgrades try-restart an active one. Never reload a foreign ruleset.
        if run(['systemctl', 'show', 'nftables.service', '--property=ActiveState', '--value']).strip() != 'inactive':
            raise ValueError('Active nftables service needs explicit host adaptation; do not stop it')
        rows = package_rows(run)
        if journal is None:
            if any(name.split(':')[0] in {*DOCKER, 'docker.io', 'containerd', 'runc', 'podman-docker'}
                   and status[1] != 'n' for name, (status, _) in rows.items()):
                raise ValueError('Existing container runtime requires explicit adoption')
            if unfinished(rows) or run(['dpkg', '--audit']).strip():
                raise ValueError('Existing unfinished package transaction must be resolved first')
            report = host_preflight.evaluate(inventory, node, collect(system_root / 'var/lib'))
            if not report['ready_for_initial_install']:
                raise ValueError('Clean-host inspection failed; run host_preflight for named blockers')
            if {item.name for item in state.iterdir()} != {'apply.lock'}:
                raise ValueError('Cannot adopt unclaimed host preparation files')
            journal = {'target': expected, 'phase': 'base', 'packages': []}
            managed_state.persist(pending, journal)
        # A saved clean-host intent is not permission to repair an application
        # host. Inspect stopped containers too, even if the daemon cannot start.
        containers = network_bootstrap.directory(system_root, 'var/lib/docker/containers')
        if containers.exists() and any(containers.iterdir()):
            raise ValueError('Container data appeared during package preparation; preserve it')
        outstanding = unfinished(rows)
        if not outstanding <= set(journal['packages']):
            raise ValueError('An unrelated unfinished package transaction must be preserved')
        if outstanding:
            run(['dpkg', '--configure', '--pending'])
        for phase, packages in (('base', BASE), ('docker', DOCKER)):
            if journal['phase'] == 'verify' or (phase == 'base' and journal['phase'] == 'docker'):
                continue
            if phase == 'docker':
                key = network_bootstrap.existing(system_root / KEY_PATH)
                if key is None:
                    key = download()
                    if hashlib.sha256(key).hexdigest() != KEY_SHA:
                        raise ValueError('Docker signing key differs from the reviewed profile')
                    network_bootstrap.directory(system_root, 'etc/apt/keyrings', create=True)
                    network_bootstrap.create_file(system_root / KEY_PATH, key)
                network_bootstrap.directory(system_root, 'etc/apt/sources.list.d', create=True)
                if network_bootstrap.existing(system_root / SOURCE_PATH) is None:
                    network_bootstrap.create_file(system_root / SOURCE_PATH, SOURCE)
            run(['apt-get', 'update'])
            arguments = ['apt-get', '--no-install-recommends', '--no-remove', 'install',
                         *(name + '=' + version for name, version in packages.items())]
            planned = closure(run([arguments[0], '--simulate', *arguments[1:]]), packages)
            journal = {'target': expected, 'phase': phase, 'packages': planned}
            managed_state.persist(pending, journal)
            run([arguments[0], '-y', *arguments[1:]])
            journal = {'target': expected, 'phase': 'docker' if phase == 'base' else 'verify', 'packages': []}
            managed_state.persist(pending, journal)
        verify_versions(package_rows(run))
        facts = collect(system_root / 'var/lib')
        report = host_preflight.evaluate(inventory, node, facts)
        if (not report['ready_for_initial_install'] or not all(facts['tools'].values()) or
                not facts.get('compose')):
            raise ValueError('Installed host failed inspection; preserve the preparation journal')
        verify_runtime(system_root, run)
        managed_state.persist(current, expected)
        clear_pending(pending)
        return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--node', required=True)
    parser.add_argument('--directory', type=Path, default=Path('/var/lib/voicechat-host'))
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    if str(args.inventory) == '-':
        raw = sys.stdin.buffer.read(65537)
        if len(raw) > 65536:
            raise ValueError('Host inventory exceeds its bound')
        inventory = json.loads(raw, object_pairs_hook=topology.unique_object)
        node_inventory.validate(inventory)
    else:
        inventory = node_inventory.load(args.inventory)
    target = binding(inventory, args.node)
    if args.execute:
        if os.geteuid() != 0:
            raise SystemExit('Host package installation requires root on the selected Linux node')
        target = install(args.directory, inventory, args.node)
    print(json.dumps({'target': target, 'base': BASE, 'docker': DOCKER,
                      'installed': args.execute, 'scope': 'Dependencies only; no role/network/DNS deployment'}))


if __name__ == '__main__':
    main()
