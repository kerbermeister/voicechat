"""Exercise crash-resumable scheduled core backups on a marked disposable Linux VM.

Starts real Synapse/control/PostgreSQL using the already cached source-built
fixture control image. Refuses existing core containers/volumes. Only synthetic
accounts and owned volumes are created; cleanup never runs on a production host.
"""
import argparse,hashlib,hmac,json,os,secrets,subprocess,sys,tempfile,urllib.request,urllib.parse
from pathlib import Path
SOURCE=Path(__file__).resolve().parents[1];sys.path[:0]=[str(SOURCE/'infra'),str(SOURCE/'prototype')]
BASE=Path('/srv/voicechat-edge-fixture')
if sys.platform!='linux' or not BASE.is_dir() or BASE.is_symlink():
 raise ValueError('Use the marked disposable Linux VM')
key=' '.join(Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2])
if json.loads((BASE/'.disposable-vm').read_text())!={'kind':'voicechat-disposable-vm','ssh_host_key_sha256':hashlib.sha256(key.encode()).hexdigest()}:
 raise ValueError('Disposable VM ownership differs from this host')
import core_deploy,managed_state,role_prepare,role_release,role_bootstrap
from topology import load
inventory=json.loads(Path('/var/lib/voicechat-network/desired.json').read_text())['inventory']
public=load(SOURCE/'infra/single-vps.example.json');public['service_id']=inventory['service_id']
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--control-image',required=True)
image=parser.parse_args().control_image
subprocess.run(['docker','image','inspect',image],check=True,stdout=subprocess.DEVNULL)
assert not subprocess.check_output(['docker','ps','-aq','--filter','label=com.docker.compose.project=voicechat']).strip()
assert not subprocess.check_output(['docker','volume','ls','-q','--filter','name=^voicechat_']).strip()
root=Path(tempfile.mkdtemp(prefix='core-rollout-',dir=SOURCE));root.chmod(0o700)
values={'LOCAL_STAND':'0','MATRIX_SERVER_NAME':public['matrix_server_name'],'PUBLIC_URL':public['canonical_origin'],'PUBLIC_IP':inventory['core']['public_ip'],'SMTP_HOST':'smtp.example.com','SMTP_PORT':'587',**{key:secrets.token_hex(32) for key in ('POSTGRES_PASSWORD','LIVEKIT_SECRET','POLICY_SECRET','REGISTRATION_SECRET','MACAROON_SECRET','TURN_SECRET')}}
releases=[]
for revision in ('a',):
 manifest=role_release.make(public,inventory,'core',revision*40,image)
 role_prepare.prepare(root,public,inventory,manifest);releases.append(manifest)
(root/'runtime/stand.env').write_text(''.join(k+'='+v+'\n' for k,v in values.items()));(root/'runtime/stand.env').chmod(0o600)
role_bootstrap.install(root,'core')
interrupt=None;backups=0;failed=False
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
base='http://'+inventory['core']['tunnel_ip']+':8088'
def api(path,body=None,token=None,method=None):
 data=None if body is None else json.dumps(body).encode()
 headers={'Content-Type':'application/json'}
 if token:headers['Authorization']='Bearer '+token
 with opener.open(urllib.request.Request(base+path,data,headers,method=method),timeout=20) as response:return json.load(response)
def execute(args,**kwargs):
 global interrupt
 completed=subprocess.run(args,capture_output=True,timeout=300,**kwargs)
 if completed.returncode:
  error=SOURCE/'core-rollout-command-error.log';error.write_bytes(completed.stdout+completed.stderr);error.chmod(0o600)
  raise RuntimeError('Core fixture command failed; private log saved')
 result=completed.stdout
 if interrupt=='resuming' and 'up' in args and args[-1]!='configure':
  interrupt=None;raise KeyboardInterrupt('Injected termination after real up')
 return result
def backup(path,record):
 global backups,interrupt
 ids=core_deploy.compose(path,record,'ps','-q','synapse','control').strip()
 assert not ids, 'Application writers must be stopped before the snapshot'
 core_deploy.backup(path,record);backups+=1
 if interrupt=='backup':
  interrupt=None;raise KeyboardInterrupt('Lost response after real backup')
 if failed:raise RuntimeError('Injected backup failure after real snapshot')
def snapshot():
 return core_deploy.backup_current(root,public,inventory,execute=execute,create_backup=backup)
current=releases[0]
result={'schema':1,'image':image,'source':'locally built fixture image from repository Dockerfile; never published','production_changed':False}
try:
 core_deploy.deploy(root,public,inventory,current,execute=execute)
 nonce=api('/_synapse/admin/v1/register')['nonce'];username='rollout_fixture';password=secrets.token_urlsafe(24)
 mac=hmac.new(values['REGISTRATION_SECRET'].encode(),'\0'.join((nonce,username,password,'notadmin')).encode(),hashlib.sha1).hexdigest()
 api('/_synapse/admin/v1/register',{'nonce':nonce,'username':username,'password':password,'admin':False,'mac':mac})
 session=api('/_matrix/client/v3/login',{'type':'m.login.password','user':username,'password':password})
 token=session['access_token'];uid=session['user_id'];device=session['device_id']
 account='/_matrix/client/v3/user/'+urllib.parse.quote(uid,safe='')+'/account_data/voicechat.rollout.fixture'
 api(account,{'sentinel':'preserved'},token,'PUT')
 prior_key=hashlib.sha256(core_deploy.compose(root,core_deploy.record_for(root,inventory,current),'run','--rm','--no-deps','-T','--entrypoint','cat','configure','/matrix/voicechat.signing.key')).hexdigest()
 def verify():
  identity=api('/_matrix/client/v3/account/whoami',token=token)
  assert identity['user_id']==uid and identity['device_id']==device
  assert api(account,token=token)=={'sentinel':'preserved'}
  key=core_deploy.compose(root,core_deploy.record_for(root,inventory,current),'run','--rm','--no-deps','-T','--entrypoint','cat','configure','/matrix/voicechat.signing.key')
  assert hashlib.sha256(key).hexdigest()==prior_key
 before=(root/'state.json').read_bytes()
 snapshot();verify();assert backups==1
 assert (root/'state.json').read_bytes()==before
 result['stopped_writer_backup_resumes_real_core_without_pointer_changes']=True
 interrupt='backup'
 try:snapshot()
 except KeyboardInterrupt:pass
 else:raise AssertionError('Expected backup interruption')
 assert managed_state.read(root/'runtime/backup.json')['phase']=='stopping'
 import role_boot
 try:role_boot.start(root,'core')
 except ValueError as error:assert 'pending core backup' in str(error)
 else:raise AssertionError('Boot must remain fenced during interrupted backup')
 count=backups;snapshot();assert backups==count+1;verify()
 result['interrupted_snapshot_fences_boot_and_repeats_backup']=True
 interrupt='resuming'
 try:snapshot()
 except KeyboardInterrupt:pass
 else:raise AssertionError('Expected resume interruption')
 assert managed_state.read(root/'runtime/backup.json')['succeeded'] is True
 count=backups;snapshot();assert backups==count;verify()
 result['interrupted_writer_resume_does_not_repeat_completed_backup']=True
 failed=True
 try:snapshot()
 except RuntimeError as error:assert 'Injected backup failure' in str(error)
 else:raise AssertionError('Expected failed backup status')
 verify();assert not (root/'runtime/backup.json').exists()
 result['failed_backup_restores_availability_and_reports_failure']=True
 assert (root/'state.json').read_bytes()==before
 result['account_device_account_data_and_signing_identity_preserved']=True
 result['limits']=['Disposable synthetic account and volumes; no production or physical device acceptance.',
                   'Scheduler installation and legacy-to-core adoption are separate integration steps.']
except BaseException:
 for service in ('postgres','synapse','control'):
  identifiers=subprocess.check_output(['docker','ps','-aq','--filter','label=com.docker.compose.project=voicechat','--filter','label=com.docker.compose.service='+service]).decode().split()
  for identifier in identifiers:
   captured=subprocess.run(['docker','logs','--tail','80',identifier],capture_output=True)
   log=SOURCE/('core-rollout-'+service+'.log');log.write_bytes(captured.stdout+captured.stderr);log.chmod(0o600)
   state=SOURCE/('core-rollout-'+service+'-state.json');state.write_bytes(subprocess.check_output(['docker','inspect','--format','{{json .State}}',identifier]));state.chmod(0o600)
 raise
finally:
 subprocess.run(['systemctl','disable','--now','voicechat-core.service'],check=True,capture_output=True)
 unit=Path('/etc/systemd/system/voicechat-core.service')
 assert unit.read_bytes()==role_bootstrap.plan(root,'core',None)[3];unit.unlink()
 subprocess.run(['systemctl','daemon-reload'],check=True)
 record=core_deploy.record_for(root,inventory,current)
 core_deploy.compose(root,record,'down','--volumes','--remove-orphans')
 import shutil
 shutil.rmtree(root)
assert not subprocess.check_output(['docker','ps','-aq','--filter','label=com.docker.compose.project=voicechat']).strip()
assert not subprocess.check_output(['docker','volume','ls','-q','--filter','name=^voicechat_']).strip()
result['fixture_resources_removed']=True
result['controller_sha256']=hashlib.sha256((SOURCE/'infra/core_deploy.py').read_bytes()).hexdigest()
(SOURCE/'.prototype').mkdir(mode=0o700,exist_ok=True)
(SOURCE/'.prototype/core-backup-current-evidence.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
