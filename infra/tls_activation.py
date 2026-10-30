"""Publish, reload and verify one running edge service under the TLS writer lock."""
import argparse
import ipaddress
import json
from pathlib import Path
import re
import socket
import ssl
import subprocess
import time

import managed_state
import tls_material
import tls_runtime
from topology import load


def docker(*arguments):
    result = subprocess.run(['docker', *arguments], capture_output=True, timeout=15)
    if result.returncode:
        raise RuntimeError('Docker TLS activation command failed; no success recorded')
    if len(result.stdout) > 65536:
        raise ValueError('Unexpected Docker activation response size')
    return result.stdout


def inspect(container, root, edge_id, service, image):
    # Never read Config.Env: it can contain unrelated credentials.
    template = ('{"id":{{json .Id}},"image":{{json .Config.Image}},'
                '"labels":{{json .Config.Labels}},"mounts":{{json .Mounts}},'
                '"running":{{json .State.Running}},"started":{{json .State.StartedAt}},'
                '"restarts":{{json .RestartCount}}}')
    value = json.loads(docker('inspect', '--format', template, container))
    labels = value.get('labels') or {}
    mounts = [item for item in value.get('mounts', []) if item.get('Destination') == '/tls']
    source = mounts[0].get('Source') if len(mounts) == 1 else None
    # Docker retains the lexical release/infra/runtime bind source. Prepared
    # releases point runtime at the stable canonical directory through a symlink.
    same_directory = (isinstance(source, str) and Path(source).is_absolute() and
                      Path(source).resolve() == root / service)
    if (value.get('id') != container or value.get('image') != image or value.get('running') is not True or
            labels.get('com.docker.compose.project') != 'voicechat-edge-' + edge_id or
            labels.get('com.docker.compose.service') != service or len(mounts) != 1 or
            mounts[0].get('Type') != 'bind' or mounts[0].get('RW') is not False or
            not same_directory):
        raise ValueError('Container image, role or read-only TLS mount does not match')
    return {key: value[key] for key in ('id', 'started', 'restarts')}


def verify_live(address, port, names, certificate, *, ca_file=None):
    context = ssl.create_default_context(cafile=ca_file)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    # Same first certificate as the verified immutable generation, not the input
    # file, which an ACME process could replace while this operation is running.
    leaf = re.search(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',
                     certificate.decode('ascii'), re.S)
    expected = ssl.PEM_cert_to_DER_cert(leaf[0])
    deadline = time.monotonic() + 15
    for name in names:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('Service did not present the selected trusted TLS certificate')
            try:
                with socket.create_connection((address, port), timeout=min(2, remaining)) as raw:
                    with context.wrap_socket(raw, server_hostname=name) as stream:
                        if stream.getpeercert(binary_form=True) == expected:
                            break
            except (OSError, ssl.SSLError):
                pass
            time.sleep(min(.1, max(0, deadline - time.monotonic())))


def activate(root, public, edge_id, service, chain_file, key_file, *, container, image,
             address, port=443, ca_file=None, minimum_validity_days=7):
    names = tls_material.names(public, edge_id, service)
    if (not isinstance(container, str) or not re.fullmatch(r'[a-f0-9]{64}', container) or
            not isinstance(image, str) or not re.fullmatch(r'[a-z0-9._/:-]+@sha256:[a-f0-9]{64}', image)):
        raise ValueError('Exact container ID and immutable image digest required')
    address = str(ipaddress.ip_address(address))
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError('Invalid TLS endpoint port')
    root = Path(root).absolute()
    if root.resolve() != root:
        raise ValueError('TLS root path must not traverse symlinks')
    with managed_state.locked(root) as root:
        before = inspect(container, root, edge_id, service, image)
        result = tls_runtime._publish_locked(root, public, edge_id, service, chain_file, key_file,
            ca_file=ca_file, minimum_validity_days=minimum_validity_days)
        receipt = root / (service + '.activation.json')
        state = {'schema': 1, 'service_id': public['service_id'], 'edge_id': edge_id,
                 'service': service, 'generation': result['generation'], 'previous': result['previous'],
                 'container': before, 'image': image, 'address': address, 'port': port, 'names': names,
                 'phase': 'pending'}
        already_verified = (receipt.exists() or receipt.is_symlink()) and managed_state.read(receipt) == {
            **state, 'phase': 'verified'}
        managed_state.persist(receipt, state)
        # A recurring renewal check with unchanged material must not drain
        # Caddy's connections. Revalidate the live certificate without a signal.
        if not already_verified:
            docker('kill', '--signal', 'SIGUSR1' if service == 'web' else 'SIGUSR2', container)
        selected = root / '.verified' / result['generation'] / (service + '.crt')
        verify_live(address, port, names, tls_material.read_material(selected, private=True), ca_file=ca_file)
        if inspect(container, root, edge_id, service, image) != before:
            raise RuntimeError('Container restarted during TLS activation; no success recorded')
        managed_state.persist(receipt, {**state, 'phase': 'verified'})
        return {**result, 'reload_required': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--topology', type=Path, required=True)
    parser.add_argument('--edge', required=True)
    parser.add_argument('--service', choices=('web', 'turn'), required=True)
    parser.add_argument('--chain', type=Path, required=True)
    parser.add_argument('--key', type=Path, required=True)
    parser.add_argument('--container', required=True)
    parser.add_argument('--image', required=True)
    parser.add_argument('--address', required=True, help='Numeric IP of this edge, independent of DNS')
    parser.add_argument('--port', type=int, default=443)
    parser.add_argument('--ca-file', type=Path, help='Explicit CA for an isolated fixture')
    parser.add_argument('--minimum-validity-days', type=int, default=7)
    args = parser.parse_args()
    result = activate(args.root, load(args.topology), args.edge, args.service, args.chain, args.key,
        container=args.container, image=args.image, address=args.address, port=args.port,
        ca_file=args.ca_file, minimum_validity_days=args.minimum_validity_days)
    print('TLS certificate verified on the same running service: ' + result['generation'])


if __name__ == '__main__': main()
