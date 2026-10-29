"""Run a host operation with the exact inventory SSH identity, without TOFU.

Remote arguments are quoted as data. Never put credentials in arguments; pass
private payloads through stdin and do not print captured output indiscriminately.
This does not provision a host or authorize production changes by itself.
"""
from contextlib import contextmanager
import os
from pathlib import Path
import shlex
import stat
import subprocess
import tempfile

import node_inventory
from tunnel_config import physical_nodes


@contextmanager
def connection(inventory, node, identity_file):
    nodes = physical_nodes(inventory)
    if node not in nodes: raise ValueError('Unknown physical SSH node')
    identity_file = Path(identity_file).absolute()
    descriptor = os.open(identity_file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError('SSH identity must be an owner-only regular file')
    finally:
        os.close(descriptor)
    with tempfile.TemporaryDirectory(prefix='voicechat-ssh-') as temporary:
        known_hosts = Path(temporary) / 'known_hosts'
        descriptor = os.open(known_hosts, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as output:
            output.write(node_inventory.known_host(inventory, nodes[node]))
        options = ('StrictHostKeyChecking=yes', 'BatchMode=yes', 'IdentitiesOnly=yes',
                   'GlobalKnownHostsFile=/dev/null', 'UserKnownHostsFile=' + str(known_hosts),
                   'HostKeyAlgorithms=ssh-ed25519', 'UpdateHostKeys=no',
                   'ForwardAgent=no', 'ClearAllForwardings=yes',
                   'ControlMaster=no', 'ControlPath=none',
                   'ConnectTimeout=10', 'ServerAliveInterval=15', 'ServerAliveCountMax=2')
        command = ['ssh', '-F', '/dev/null', '-T', '-i', str(identity_file), '-p', str(inventory['ssh_port'])]
        for option in options: command.extend(('-o', option))
        command += ['--', inventory['ssh_user'] + '@' + nodes[node]['public_ip']]
        yield command


def execute(inventory, node, identity_file, arguments, *, input=None, timeout=120):
    if (not isinstance(arguments, (list, tuple)) or not arguments or
            any(not isinstance(value, str) or '\x00' in value for value in arguments) or
            not arguments[0]):
        raise ValueError('Nonempty remote argument vector required')
    if type(timeout) is not int or not 1 <= timeout <= 3600:
        raise ValueError('Bounded SSH operation timeout required')
    with connection(inventory, node, identity_file) as command:
        return subprocess.run([*command, shlex.join(arguments)], input=input, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=timeout, check=True)
