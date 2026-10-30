"""External read-only health checks; no deployment, profiles or secret output."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import time
from urllib.parse import urlsplit

import entry_probe
import host_connection
import node_diagnostics
import node_inventory
import topology

REMOTE = r'''from pathlib import Path
import json,sys,time
root=Path(sys.argv[1]);assert root.is_absolute() and root.resolve()==root
journal=json.loads((root/'rollout.json').read_text())
source=journal['request']['source'];assert len(source)==64 and all(c in '0123456789abcdef' for c in source)
sys.path.insert(0,str(root/'bundles'/source/'infra'))
import managed_journal,managed_state,node_diagnostics
managed_journal._delivery(root,source)
_,baseline,_=managed_journal.current(root)
report=node_diagnostics.report(root,baseline['public'],baseline['inventory'],'core',subnet=baseline['subnet'])
maintenance=[]
if journal['phase'] not in ('complete','rolled-back'):maintenance.append(root/'rollout.json')
backup=root/'core/runtime/backup.json'
if backup.exists():maintenance.append(backup)
active=bool(maintenance) and all(0<=time.time()-p.stat().st_mtime<900 for p in maintenance)
print(json.dumps({'report':report,'maintenance':active}))
'''


def inspect_core(config, identity):
    with host_connection.connection(config['inventory'], 'core', identity) as ssh:
        result = subprocess.run([*ssh, shlex.join(['python3', '-B', '-c', REMOTE, config['root']])],
                                capture_output=True, timeout=90)
    if result.returncode or len(result.stdout) > 65536:
        raise ValueError('Core diagnostic unavailable')
    value = json.loads(result.stdout, object_pairs_hook=topology.unique_object)
    report = value['report']
    if (type(value['maintenance']) is not bool or type(report['schema']) is not int or report['schema'] != 1 or report['node'] != 'core' or
            report['service_id'] != config['public']['service_id'] or
            type(report['generation']) is not int or report['generation'] != config['inventory']['core']['generation'] or
            type(report['checked_at']) is not int or not -30 <= time.time()-report['checked_at'] <= 300):
        raise ValueError('Unexpected core diagnostic identity or time')
    expected = {'network', 'matrix', 'control', 'core_processes', 'disk'}
    for edge in config['inventory']['edges']:
        if edge.get('host') == 'core':
            expected.update('edge_'+edge['id']+suffix for suffix in ('_processes', '_web_tls', '_turn_tls'))
    if set(report['checks']) != expected:
        raise ValueError('Incomplete core diagnostic')
    return value


def outcome(checks, maintenance):
    failures = [name for name, value in checks.items() if value != 'passed']
    # Maintenance never hides missing SSH, TLS renewal or low disk space.
    planned = {'core_network', 'core_matrix', 'core_control', 'core_core_processes'}
    planned.update(name for name in checks if name.endswith('_processes') or name.endswith('_route'))
    if failures and (not maintenance or any(name not in planned for name in failures)):
        return 'failed'
    return 'maintenance' if maintenance else 'healthy'


def probe(operation):
    try:
        operation()
        return 'passed'
    except Exception:
        return 'failed'  # Never expose subprocess stderr, credentials or raw URLs.


def monitor(config, identity):
    node_inventory.validate(config['inventory'], config['public'])
    root = config['root']
    if not isinstance(root, str) or not re.fullmatch(r'/[A-Za-z0-9/_-]+', root) or '..' in Path(root).parts or root == '/':
        raise ValueError('Canonical managed root required')
    checks = {}; maintenance = False
    for edge in config['public']['edges']:
        identifier = edge['id']; assignment = node_inventory.edge_assignment(config['inventory'], identifier)
        def dns(edge=edge, assignment=assignment):
            addresses = {str(ipaddress.ip_address(item[4][0])) for item in socket.getaddrinfo(
                urlsplit(edge['origin']).hostname, 443, type=socket.SOCK_STREAM)}
            if addresses != {assignment['public_ip']}:raise ValueError('DNS differs from inventory')
        checks[identifier+'_dns'] = probe(dns)
        checks[identifier+'_route'] = probe(lambda: entry_probe.ready(config['public'], config['inventory'], identifier))
        for kind, host in (('web', urlsplit(edge['origin']).hostname), ('turn', edge['turn_host'])):
            def certificate(host=host):
                value = node_diagnostics.tls(host, host)
                if value['status'] != 'passed' or value['renewal_due']:raise ValueError('TLS renewal required')
            checks[identifier+'_'+kind+'_tls'] = probe(certificate)
    try:
        value = inspect_core(config, identity); maintenance = value['maintenance']
        for name, check in value['report']['checks'].items():
            if check.get('status') not in ('passed', 'failed'):raise ValueError('Unknown check status')
            checks['core_'+name] = 'passed' if check['status']=='passed' and not check.get('renewal_due', False) else 'failed'
        checks['core_ssh'] = 'passed'
    except Exception:
        checks['core_ssh'] = 'failed'
    return {'schema':1, 'checked_at':int(time.time()), 'status':outcome(checks, maintenance),
            'checks':checks, 'maintenance':maintenance,
            'not_checked':['authenticated_chat_and_wss','decrypted_media','physical_clients']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity', type=Path, default=Path.home()/'.ssh/id_ed25519')
    args = parser.parse_args()
    try:
        config = json.loads(os.environ['SERVER_ROLE_CONFIG'], object_pairs_hook=topology.unique_object)
        if config['root'] != os.environ['DEPLOY_ROOT']:raise ValueError('Unexpected managed root')
        value = monitor(config, args.identity)
    except Exception:
        value = {'schema':1, 'status':'failed', 'checks':{'monitor_configuration':'failed'}}
    print(json.dumps(value, sort_keys=True))
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as output:
            output.write('VoiceChat external monitor: **'+value['status']+'**\n\n')
            for name, status in value['checks'].items():output.write('- '+name+': '+status+'\n')
            output.write('\nThis does not verify encrypted chat or media.\n')
    raise SystemExit(0 if value['status'] in ('healthy','maintenance') else 1)


if __name__ == '__main__':main()
