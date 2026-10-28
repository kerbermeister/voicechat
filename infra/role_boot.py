"""Start only a committed, verified role after its network and Docker are ready."""
import argparse
import subprocess
import os
import signal
import socket
import time
from pathlib import Path

import core_deploy
import edge_deploy
import managed_state
import network_runtime
import node_inventory
import role_bootstrap
import role_deploy
import role_release


def start(root, role, edge_id=None, *, execute=role_deploy.run, network_directory=Path('/var/lib/voicechat-network')):
    root = Path(root).absolute()
    if root.resolve() != root: raise ValueError('Role root must not traverse symlinks')
    with managed_state.locked(root):
        role_bootstrap.ready(root, role, edge_id)
        state = core_deploy.read_state(root) if role == 'core' else edge_deploy.read_state(root, edge_id)
        if state['pending'] is not None and state['pending']['phase'] != 'prepared':
            raise ValueError('Resume the pending deployment before starting this role')
        record = state['current']
        if record is None: raise ValueError('No committed role is available to start')
        role_deploy.release_path(root, record)
        desired = managed_state.read(network_directory / 'desired.json')
        network_runtime.components(desired)
        inventory, subnet = desired['inventory'], desired['edge_subnet']
        assignment = inventory['core'] if role == 'core' else node_inventory.edge_assignment(inventory, edge_id)
        if role_release.json_digest(assignment) != record['manifest']['node_sha256']:
            raise ValueError('Committed role does not belong to this network host')
        node = 'core' if role == 'core' or next(item for item in inventory['edges'] if item['id'] == edge_id).get('host') == 'core' else 'edge-' + edge_id
        with role_deploy.network_ready(inventory, node, subnet, execute=execute, directory=network_directory):
            if role == 'core':
                if core_deploy.runtime_digest(root) != record['runtime_sha256']:
                    raise ValueError('Core runtime changed since the committed release')
                if core_deploy.data_identity(root, record, execute=execute) != state['data_identity']:
                    raise ValueError('Core data identity changed; refusing to initialize replacement data')
                try:
                    core_deploy.healthy(root, record, execute=execute)
                except (ValueError, OSError, RuntimeError, subprocess.SubprocessError):
                    core_deploy.compose(root, record, 'up', '-d', '--no-deps', '--wait', '--wait-timeout', '180', 'postgres', execute=execute)
                    core_deploy.compose(root, record, 'up', '-d', '--no-deps', '--wait', '--wait-timeout', '180', 'synapse', 'control', execute=execute)
                    core_deploy.healthy(root, record, execute=execute)
            else:
                with managed_state.locked(root / 'runtime/tls'):
                    for service in ('web', 'turn'): edge_deploy.certificate(root, record, service)
                    try:
                        edge_deploy.healthy(root, record, execute=execute)
                    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError):
                        edge_deploy.compose(root, record, 'up', '-d', '--no-deps', '--wait', '--wait-timeout', '180', *services(role, record), execute=execute)
                        edge_deploy.healthy(root, record, execute=execute)
    return record


def services(role, record=None):
    if role == 'core': return ('postgres', 'synapse', 'control')
    return tuple(name for name in ('route-health', 'web', 'turn', 'ingress')
                 if record is None or name in record['manifest']['images'])


def stop(root, role, edge_id=None, *, execute=role_deploy.run):
    try:
        with managed_state.locked(root):
            state = core_deploy.read_state(root) if role == 'core' else edge_deploy.read_state(root, edge_id)
            if state['pending'] is not None and state['pending']['phase'] != 'prepared': return
            record = state['current']
            if record is None: return
            compose = core_deploy.compose if role == 'core' else edge_deploy.compose
            if role == 'core':
                compose(root, record, 'stop', 'synapse', 'control', execute=execute)
                compose(root, record, 'stop', 'postgres', execute=execute)
            else:
                compose(root, record, 'stop', *services(role, record), execute=execute)
    except BlockingIOError:
        # The deployment that owns the lock also owns maintenance shutdown.
        return


def notify_ready():
    address = os.environ.get('NOTIFY_SOCKET')
    if not address: return
    if address.startswith('@'): address = '\0' + address[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as stream:
        stream.connect(address)
        stream.sendall(b'READY=1')


def watch(root, role, edge_id=None, *, execute=role_deploy.run):
    """Exit on a failed container; systemd restarts only the committed role.

    Planned maintenance exits successfully so the monitor cannot race backup or
    rollback. The deployment controller reactivates it after releasing its locks.
    """
    root = Path(root).absolute()
    stopping = False
    def terminate(*_):
        nonlocal stopping
        stopping = True
    previous = {number: signal.signal(number, terminate) for number in (signal.SIGTERM, signal.SIGINT)}
    waiters = []
    try:
        record = start(root, role, edge_id, execute=execute)
        compose = core_deploy.compose if role == 'core' else edge_deploy.compose
        identifiers = compose(root, record, 'ps', '-q', *services(role, record), execute=execute).decode().split()
        if len(identifiers) != len(services(role, record)): raise ValueError('Role services disappeared before monitoring')
        for identifier in identifiers:
            waiters.append(subprocess.Popen(['docker', 'wait', identifier], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        notify_ready()
        while not stopping:
            if any(waiter.poll() is not None for waiter in waiters):
                state = core_deploy.read_state(root) if role == 'core' else edge_deploy.read_state(root, edge_id)
                pending = state['pending']
                return 0 if pending is not None and pending['phase'] != 'prepared' else 1
            time.sleep(.5)
        stop(root, role, edge_id, execute=execute)
        return 0
    finally:
        for waiter in waiters:
            if waiter.poll() is None: waiter.terminate()
        for waiter in waiters:
            try: waiter.wait(timeout=5)
            except subprocess.TimeoutExpired:
                waiter.kill()
                waiter.wait(timeout=5)
        for number, handler in previous.items(): signal.signal(number, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--role', choices=('core', 'edge'), required=True)
    parser.add_argument('--edge')
    parser.add_argument('--watch', action='store_true', help='Notify systemd readiness and monitor critical containers')
    args = parser.parse_args()
    if (args.role == 'edge') != (args.edge is not None): parser.error('Only edge roles require --edge')
    if args.watch:
        raise SystemExit(watch(args.root, args.role, args.edge))
    start(args.root, args.role, args.edge)
    print('Committed role started and verified; deployment state unchanged.')


if __name__ == '__main__': main()
