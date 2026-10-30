"""Real cohost TLS renewal on the marked disposable shared-port VM fixture.

Actual Caddy/coturn edge images and signals, synthetic Caddy certificate storage
and no real upstream account, ACME issuance, media or production changes.
"""
import argparse
import json
from pathlib import Path
import secrets
import shutil
import sys
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import cohost_tls
import cohost_tls_bootstrap
import network_bootstrap
import edge_deploy
import managed_state
import role_prepare
import role_release
import shared_ingress
import tls_activation
import check_shared_front_warm
import check_shared_port_cutover



def installed_timer(root, ca, target, run):
    """Trust only the disposable fixture CA while exercising the real unit."""
    trust = Path('/usr/local/share/ca-certificates/voicechat-cohost-fixture.crt')
    if trust.exists() or trust.is_symlink():
        raise ValueError('Existing trust source must not be replaced')
    record = {'schema': 1, 'root': str(root), 'operator': target['operator']}
    expected = cohost_tls_bootstrap.files(record, system_root=Path('/'))
    units = {name: Path('/etc/systemd/system') / name for name in expected}
    for path in units.values():
        if path.exists() or path.is_symlink() or path.with_name(path.name + '.d').exists():
            raise ValueError('Existing renewal scheduler must not be replaced')
    certificate = ca.read_bytes()
    try:
        with trust.open('xb') as output: output.write(certificate)
        run(['update-ca-certificates'])
        installed = cohost_tls_bootstrap.install(root)
        if installed != record: raise AssertionError('Installed renewal operator differs from reviewed fixture')
        run(['systemctl', 'start', cohost_tls_bootstrap.SERVICE])
        status = run(['systemctl', 'show', cohost_tls_bootstrap.SERVICE,
            '--property=ActiveState,Result,ExecMainStatus']).decode()
        fields = dict(line.split('=', 1) for line in status.splitlines() if '=' in line)
        if fields != {'ActiveState': 'inactive', 'Result': 'success', 'ExecMainStatus': '0'}:
            raise AssertionError('Installed sealed renewal service did not succeed')
        run(['systemctl', 'is-enabled', '--quiet', cohost_tls_bootstrap.TIMER])
        run(['systemctl', 'is-active', '--quiet', cohost_tls_bootstrap.TIMER])
    finally:
        try:
            # Stop only these new fixture TLS units, never a backup or Docker.
            if network_bootstrap.existing(units[cohost_tls_bootstrap.TIMER]) == expected[cohost_tls_bootstrap.TIMER]:
                run(['systemctl', 'disable', '--now', cohost_tls_bootstrap.TIMER])
            if network_bootstrap.existing(units[cohost_tls_bootstrap.SERVICE]) == expected[cohost_tls_bootstrap.SERVICE]:
                run(['systemctl', 'stop', cohost_tls_bootstrap.SERVICE])
            for name, path in units.items():
                value = network_bootstrap.existing(path)
                if value is not None:
                    if value != expected[name]: raise ValueError('Modified fixture TLS unit must be preserved')
                    path.unlink()
            run(['systemctl', 'daemon-reload'])
        finally:
            if trust.read_bytes() != certificate: raise ValueError('Modified fixture trust source must be preserved')
            trust.unlink()
            run(['update-ca-certificates'])


def renewal(directory, edge, public, inventory, run, *, web_image):
    print('Renewal fixture: starting real edge backends', file=sys.stderr, flush=True)
    root = directory / 'shared'
    edge_id = 'warmfixture'
    project = 'voicechat-edge-' + edge_id
    if run(['docker','ps','-aq','--filter','label=com.docker.compose.project='+project]).strip():
        raise ValueError('Existing edge containers must not be adopted by the fixture')
    volume = project + '_turn-config'
    if run(['docker','volume','ls','-q','--filter','name=^'+volume+'$']).strip():
        raise ValueError('Existing edge config volume must not be adopted by the fixture')
    # Remove only the explicitly owned synthetic Caddy backends from the parent
    # warm proof. Their replacements run the unmodified generated edge Compose.
    for service in ('web','turn'):
        name='vc-warm-'+service+'-'+directory.name
        if run(['docker','inspect','--format','{{index .Config.Labels "voicechat.fixture"}}',name]).decode().strip()!=directory.name:
            raise ValueError('Foreign warm backend must be preserved')
        run(['docker','rm','-f',name])
    manifest=role_release.make(public,inventory,'edge','b'*40,web_image,edge_id,'10.243.0.0/28')
    role_prepare.prepare(edge,public,inventory,manifest,'10.243.0.0/28')
    record=edge_deploy.record_for(public,inventory,manifest)
    secret=edge/'runtime/turn-secret'
    with secret.open('x') as output:
        secret.chmod(0o600);output.write(secrets.token_hex(32))
    ca=directory/'ca.crt'
    mount=Path(run(['docker','volume','inspect','--format','{{.Mountpoint}}','deploy_caddy_data']).decode().strip())
    cache=mount/'caddy/certificates'/cohost_tls.ISSUER
    for hostname in ('chat.fixture.invalid','turn.fixture.invalid'):
        source=cache/hostname;source.mkdir(mode=0o700,parents=True)
        for suffix,filename in (('crt','server.chain'),('key','server.key')):
            target=source/(hostname+'.'+suffix);target.write_bytes((directory/filename).read_bytes());target.chmod(0o600)
    original_web={suffix:(cache/'chat.fixture.invalid'/('chat.fixture.invalid.'+suffix)).read_bytes() for suffix in ('crt','key')}
    def compose(*args):return edge_deploy.compose(edge,record,*args)
    anonymous=[]
    try:
        compose('up','-d','--pull','never','--wait','--wait-timeout','180')
        managed_state.persist(edge/'state.json',{'schema':1,'current':record,'previous':None,'pending':None})
        identifiers=compose('ps','-q','web','turn').decode().split()
        if len(identifiers)!=2:raise AssertionError('Missing real edge TLS containers')
        for identifier in identifiers:
            for item in json.loads(run(['docker','inspect','--format','{{json .Mounts}}',identifier])):
                if item.get('Destination')=='/var/lib/coturn':anonymous.append(item['Name'])
        def processes():return run(['docker','inspect','--format','{{.Id}} {{.State.StartedAt}} {{.RestartCount}}',*identifiers])
        before=processes()
        target=shared_ingress.read_plan(root,root/'plans'/managed_state.read(root/'current.json')['plan'])[0]
        if target['mode']!='shared':raise AssertionError('Expected committed public shared fixture')
        # The filesystem layout is synthetic ACME storage. The controller still
        # validates its ownership, chain, key, identities and real live edge TLS.
        print('Renewal fixture: initial live activation', file=sys.stderr, flush=True)
        first=cohost_tls.refresh(root,ca_file=ca)
        for service in ('web','turn'):
            receipt=managed_state.read(edge/'runtime/tls'/(service+'.activation.json'))
            if receipt['phase']!='verified' or receipt['address']!='127.0.0.1' or receipt['port']!=19443:
                raise AssertionError('Activation did not use the owned edge loopback')
        source=cache/'chat.fixture.invalid'
        key=directory/'renewed.key';key.touch(mode=0o600)
        csr=directory/'renewed.csr';leaf=directory/'renewed.crt'
        run(['openssl','req','-new','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes',
            '-keyout',str(key),'-out',str(csr),'-subj','/CN=chat.fixture.invalid'])
        run(['openssl','x509','-req','-in',str(csr),'-CA',str(ca),'-CAkey',str(directory/'ca.key'),
            '-CAcreateserial','-out',str(leaf),'-days','14','-extfile',str(directory/'server.ext')])
        (source/'chat.fixture.invalid.crt').write_bytes(leaf.read_bytes()+ca.read_bytes())
        (source/'chat.fixture.invalid.key').write_bytes(key.read_bytes())
        original_docker=tls_activation.docker;signals=[];lose=True
        def interrupted(*args):
            nonlocal lose
            result=original_docker(*args)
            if args[0]=='kill':
                signals.append(args)
                if lose:
                    lose=False;raise SystemExit('Lost actual certificate reload reply')
            return result
        with patch.object(tls_activation,'docker',side_effect=interrupted):
            try:cohost_tls.refresh(root,ca_file=ca)
            except SystemExit:pass
            else:raise AssertionError('Expected lost reload reply')
            if managed_state.read(edge/'runtime/tls/web.activation.json')['phase']!='pending':
                raise AssertionError('Interrupted activation lost its pending receipt')
            renewed=cohost_tls.refresh(root,ca_file=ca)
            if renewed['generations']['web']==first['generations']['web'] or renewed['generations']['turn']!=first['generations']['turn']:
                raise AssertionError('Renewal did not rotate only the new web pair')
            count=len(signals)
            if cohost_tls.refresh(root,ca_file=ca)!=renewed or len(signals)!=count:
                raise AssertionError('Unchanged periodic renewal unnecessarily signaled TLS services')
        for suffix,value in original_web.items():(source/('chat.fixture.invalid.'+suffix)).write_bytes(value)
        if cohost_tls.refresh(root,ca_file=ca)!=first:raise AssertionError('Verified previous pair did not restore')
        print('Renewal fixture: installed sealed systemd service', file=sys.stderr, flush=True)
        installed_timer(root, ca, target, run)
        if processes()!=before:raise AssertionError('TLS refresh restarted an edge container')
        return {'core_and_edge_not_started':False, 'core_not_started':True,
            'edge_services_started_for_refresh':True,
            'actual_installed_sealed_renewal_service_succeeded':True,
            'owned_timer_enabled_and_fixture_trust_restored':True,
            'actual_cohost_refresh_real_caddy_and_coturn':True,
            'actual_web_rotation_and_lost_signal_response_resumed':True,
            'unchanged_pairs_periodic_repeat_sent_no_signals':True,
            'previous_valid_pair_restored':True,
            'both_live_pairs_verified_through_owned_loopback':True,
            'edge_container_processes_preserved_during_refresh':True,
            'renewal_limits':['Synthetic ACME storage, actual cached web and pinned coturn images.',
                              'No real ACME issuance/renewal, core account, media, active TURN allocation or reboot.']}
    finally:
        compose('down','--volumes','--remove-orphans')
        for name in anonymous:
            if run(['docker','volume','ls','-q','--filter','name=^'+name+'$']).strip():
                labels=json.loads(run(['docker','volume','inspect','--format','{{json .Labels}}',name]))
                if 'com.docker.volume.anonymous' not in (labels or {}):raise ValueError('Foreign TURN runtime must be preserved')
                run(['docker','volume','rm',name])
        if run(['docker','ps','-aq','--filter','label=com.docker.compose.project='+project]).strip():
            raise AssertionError('Fixture edge containers remain')
        if run(['docker','volume','ls','-q','--filter','name=^'+volume+'$']).strip():
            raise AssertionError('Fixture turn config remains')


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--web-image',required=True)
    args=parser.parse_args()
    exercise=check_shared_port_cutover.exercise
    def with_renewal(*params):
        return exercise(*params,after_commit=lambda *values:renewal(*values,web_image=args.web_image))
    with patch.object(check_shared_port_cutover,'exercise',side_effect=with_renewal):
        check_shared_front_warm.main(cutover=True)


if __name__=='__main__':main()
