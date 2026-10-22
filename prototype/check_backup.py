"""Restore the isolated local Docker stand into a disposable database; never production."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'infra'))
from deploy import backup, compose, execute, RESTIC

repo=Path(__file__).resolve().parents[1]
env=os.environ.copy()
config=json.loads(subprocess.check_output(['docker','compose','-f',str(repo/'infra/compose.yaml'),
    '--env-file',str(repo/'infra/runtime/stand.env'),'config','--format','json']))
assert config['services']['configure']['environment']['LOCAL_STAND']=='1', 'Only the isolated local stand is allowed'
root=repo/'.prototype/deploy-backup-test'
root.mkdir(mode=0o700,exist_ok=True)
(root/'runtime').mkdir(mode=0o700,exist_ok=True)
shutil.copyfile(repo/'infra/runtime/stand.env',root/'runtime/stand.env')
(root/'runtime/stand.env').chmod(0o600)

def sql(database, query):
    return subprocess.check_output(['docker','compose','-f',str(repo/'infra/compose.yaml'),
        '--env-file',str(repo/'infra/runtime/stand.env'),'exec','-T','postgres',
        'psql','-U','synapse','-d',database,'-At','-c',query],text=True).strip()

writers=('web','synapse','control','turn')
compose(repo,env,'stop',*writers)
try:
    expected=sql('synapse',"SELECT count(*) FROM users; SELECT count(*) FROM events WHERE type='m.room.encrypted';")
    assert all(int(count)>0 for count in expected.splitlines()), 'Create disposable users and messages on :7360 first'
    backup(root,repo,env)
finally:
    compose(repo,env,'up','-d','--wait','--wait-timeout','180')

restored=root/('restore-'+str(time.time_ns()))
restored.mkdir(mode=0o700)
execute(['docker','run','--rm','-e','RESTIC_PASSWORD_FILE=/password',
    '-v',f'{root}/runtime/backup-password:/password:ro',
    '-v',f'{root}/backups/repository:/repository:ro','-v',f'{restored}:/restore',
    RESTIC,'-r','/repository','--no-lock','restore','latest','--target','/restore'])
python=config['services']['configure']['image']
check="""from pathlib import Path
import hashlib
for name in ('homeserver.yaml','voicechat.signing.key'):
 assert hashlib.sha256(Path('/original',name).read_bytes()).digest()==hashlib.sha256(Path('/restored/snapshot/synapse',name).read_bytes()).digest()
assert list(Path('/restored/snapshot/control').rglob('*.sqlite*'))
"""
execute(['docker','run','--rm','-v',f'{restored}:/restored:ro','-v','voicechat_synapse:/original:ro',
    python,'python3','-c',check])
database='restore_check_'+str(time.time_ns())
compose(repo,env,'exec','-T','postgres','createdb','-U','synapse',database)
try:
    read=subprocess.Popen(['docker','run','--rm','-v',f'{restored}:/restored:ro',python,'python3','-c',
        "from pathlib import Path;import sys;sys.stdout.buffer.write(Path('/restored/snapshot/database/postgres.dump').read_bytes())"],stdout=subprocess.PIPE)
    try:
        compose(repo,env,'exec','-T','postgres','pg_restore','-U','synapse','--no-owner','--exit-on-error','-d',database,stdin=read.stdout)
    finally:
        read.stdout.close()
        assert read.wait()==0
    actual=sql(database,"SELECT count(*) FROM users; SELECT count(*) FROM events WHERE type='m.room.encrypted';")
    assert actual==expected, 'Restored users and encrypted events differ from the consistent snapshot'
finally:
    compose(repo,env,'exec','-T','postgres','dropdb','-U','synapse',database)
report={'run':str(int(time.time())),'result':'PASS','encrypted_repository_checked':True,
        'synapse_signing_and_config_match':True,'control_state_restored':True,'postgres_restore_counts_match':True}
(repo/'prototype/verified-backup-run.json').write_text(json.dumps(report,indent=2)+'\n')
print('PASS: encrypted consistent backup, restored signing/config/control and isolated PostgreSQL users/encrypted events')
