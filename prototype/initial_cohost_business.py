"""Synthetic neighboring site and adopted ingress for the full VM migration proof.

Caller owns the marked VM, its fixture directory and an existing legacy API
alias on the supplied external network. This fixture never reads production keys.
"""
from contextlib import contextmanager
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'infra'))
import cohost_tls
import managed_state
import role_config
import role_deploy
import shared_config
import shared_front
import shared_ingress as ingress
import shared_update


@contextmanager
def business(directory, edge, public, inventory, network, *, run=role_deploy.run):
    root,repo=directory/'shared',directory/'repo'
    wrapper=Path('/usr/local/sbin/voicechat-shared-deploy')
    trust=Path('/usr/local/share/ca-certificates/voicechat-initial-cohost-fixture.crt')
    for path in (wrapper,trust):
        if path.exists() or path.is_symlink():raise ValueError('Existing operator/trust must be preserved')
    if run(['docker','ps','-aq','--filter','label=com.docker.compose.project=deploy']).strip():
        raise ValueError('Existing business containers must be preserved')
    for name in ('deploy_caddy_data','deploy_caddy_config'):
        if run(['docker','volume','ls','-q','--filter','name=^'+name+'$']).strip():
            raise ValueError('Existing Caddy data must be preserved')
    profile=inventory['edges'][0]['shared_tls']
    if run(['docker','network','ls','-q','--filter','name=^'+profile['network']+'$']).strip():
        raise ValueError('Existing fixture TLS bridge must be preserved before setup')
    deploy=repo/'deploy';deploy.mkdir(parents=True)
    ca,ca_key,leaf,key,chain=(directory/name for name in ('ca.crt','ca.key','server.crt','server.key','server.chain'))
    run(['openssl','req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes',
         '-keyout',str(ca_key),'-out',str(ca),'-days','30','-subj','/CN=Disposable Initial Cohost CA',
         '-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,keyCertSign,cRLSign'])
    extensions=directory/'server.ext';csr=directory/'server.csr'
    extensions.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n'
        'extendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n'
        'subjectAltName=DNS:chat.fixture.invalid,DNS:turn.fixture.invalid,DNS:neighbor.fixture.invalid\n')
    run(['openssl','req','-new','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes',
         '-keyout',str(key),'-out',str(csr),'-subj','/CN=chat.fixture.invalid'])
    run(['openssl','x509','-req','-in',str(csr),'-CA',str(ca),'-CAkey',str(ca_key),'-CAcreateserial',
         '-out',str(leaf),'-days','14','-extfile',str(extensions)])
    ca_key.chmod(0o600);key.chmod(0o600);chain.write_bytes(leaf.read_bytes()+ca.read_bytes())
    routes='{$DOMAIN} {\n    tls /data/fixture.crt /data/fixture.key\n    reverse_proxy frontend:80\n}\n'
    (deploy/'Caddyfile').write_text(routes)
    (deploy/'upstream.py').write_text('from http.server import BaseHTTPRequestHandler,HTTPServer\n'
        'class Handler(BaseHTTPRequestHandler):\n'
        ' def do_GET(self):\n  self.send_response(200);self.end_headers();self.wfile.write(b"fixture-neighbor")\n'
        ' def log_message(self,*_):pass\nHTTPServer(("0.0.0.0",80),Handler).serve_forever()\n')
    model={'name':'deploy','services':{
        'caddy':{'image':ingress.CADDY_IMAGE,'restart':'unless-stopped','environment':{'DOMAIN':'${DOMAIN:?}'},
            'ports':['80:80','443:443'],'volumes':['./Caddyfile:/etc/caddy/Caddyfile:ro','caddy_data:/data','caddy_config:/config'],
            'depends_on':{'frontend':{'condition':'service_healthy'}}},
        'frontend':{'image':role_config.pinned_image('configure'),'entrypoint':['python3','/upstream.py'],
            'volumes':['./upstream.py:/upstream.py:ro'],'environment':{'PYTHONDONTWRITEBYTECODE':'1'},
            'healthcheck':{'test':['CMD','python3','-c',
                'import http.client; c=http.client.HTTPConnection("127.0.0.1",80,timeout=2); c.request("GET","/"); assert c.getresponse().status==200'],
                'interval':'1s','timeout':'3s','retries':60}}},
        'volumes':{'caddy_data':{},'caddy_config':{}},'networks':{'default':{'external':True,'name':network}}}
    source=deploy/'docker-compose.yml';source.write_text(json.dumps(model))
    environment=deploy/'.env';environment.write_text('DOMAIN=neighbor.fixture.invalid\n');environment.chmod(0o600)
    run(['git','-C',str(repo),'init','-b','main'])
    run(['git','-C',str(repo),'add','deploy'])
    run(['git','-C',str(repo),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-m','fixture'])
    remote=directory/'business.git';run(['git','clone','--bare',str(repo),str(remote)])
    run(['git','-C',str(repo),'remote','add','origin',str(remote)])
    (deploy/'Caddyfile').write_text(ingress.legacy_config(routes,public))
    command=['docker','compose','--env-file',str(environment),'--project-name','deploy','-f',str(source)]
    def execute(args,**kwargs):
        # The disposable manual certificate lives in Caddy's owned volume.
        # Mount it for config validation only; runtime deployment is unmodified.
        if args[:2]==['docker','run'] and 'validate' in args and '--mount' not in args:
            index=args.index(ingress.CADDY_IMAGE)
            args=[*args[:index],'--mount','type=volume,source=deploy_caddy_data,target=/data,readonly,volume-nocopy',*args[index:]]
        return run(args,**kwargs)
    trust_installed=False
    try:
        for name in ('caddy_data','caddy_config'):
            run(['docker','volume','create','--label','com.docker.compose.project=deploy',
                 '--label','com.docker.compose.volume='+name,'deploy_'+name])
        mount=Path(run(['docker','volume','inspect','--format','{{.Mountpoint}}','deploy_caddy_data']).decode().strip())
        for filename,raw,mode in (('fixture.crt',chain.read_bytes(),0o644),('fixture.key',key.read_bytes(),0o600)):
            target=mount/filename;target.write_bytes(raw);target.chmod(mode)
        cache=mount/'caddy/certificates'/cohost_tls.ISSUER
        for hostname in ('chat.fixture.invalid','turn.fixture.invalid'):
            folder=cache/hostname;folder.mkdir(parents=True,mode=0o700)
            for suffix,raw in (('crt',chain.read_bytes()),('key',key.read_bytes())):
                target=folder/(hostname+'.'+suffix);target.write_bytes(raw);target.chmod(0o600)
        with trust.open('xb') as output:output.write(ca.read_bytes())
        trust_installed=True;run(['update-ca-certificates'])
        run([*command,'up','-d','--wait','--wait-timeout','60'])
        edge_id=public['edges'][0]['id']
        plan=ingress.stage(root,repo,edge,public,inventory,edge_id,routes)
        ingress.adopt_legacy(root,plan,execute=execute)
        shared_update.install(root,execute=execute)
        certificates=ingress.stage(root,repo,edge,public,inventory,edge_id,routes,mode='legacy-certs')
        shared_config.prepare_certificates(root,certificates,execute=execute)
        yield root,execute,ca
    finally:
        if wrapper.exists() or wrapper.is_symlink():
            operator=managed_state.read(root/'manager.json')['operator']
            if wrapper.is_symlink() or wrapper.read_bytes()!=shared_update._wrapper(root,operator):
                raise ValueError('Modified operator must be preserved')
            wrapper.unlink()
        run([*command,'down','--volumes','--remove-orphans'])
        # Caddy used this external bridge until business down. Front down before
        # that point cannot remove it while Caddy is attached.
        warm=root/'front/warm.json'
        if warm.exists():
            plan=root/'front/plans'/managed_state.read(warm)['plan']
            _,front_model=shared_front.read_plan(root/'front',plan)
            shared_front._networks(front_model,execute=run,owned=True)
            for network_value in front_model['networks'].values():
                name=network_value['name']
                if run(['docker','network','ls','-q','--filter','name=^'+name+'$']).strip():
                    if json.loads(run(['docker','network','inspect','--format','{{json .Containers}}',name])):
                        raise ValueError('Attached fixture bridge must be preserved')
                    run(['docker','network','rm',name])
        if trust_installed:
            if trust.read_bytes()!=ca.read_bytes():raise ValueError('Modified trust must be preserved')
            trust.unlink();run(['update-ca-certificates'])
