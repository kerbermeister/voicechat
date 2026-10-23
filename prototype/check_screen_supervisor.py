#!/usr/bin/env python3
"""Изолированный реальный control/SFU container; без портов, аккаунтов и production."""
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time

IMAGE='voicechat-screen-control:test'

def main():
    start=time.monotonic()
    name='voicechat-screen-check-'+secrets.token_hex(6)
    report={'result':'FAIL','scope':'real pinned SFU + control process lifecycle; no live media'}
    def docker(*args,input=None,timeout=20,env=None):
        return subprocess.check_output(['docker',*args],input=input,text=True,stderr=subprocess.DEVNULL,timeout=timeout,env=env).strip()
    try:
        with tempfile.TemporaryDirectory(prefix='voicechat-screen-') as directory:
            key=secrets.token_hex(32)
            config=Path(directory)/'livekit.json'
            config.write_text(json.dumps({'port':7880,'bind_addresses':['127.0.0.1'],
                'keys':{'prototype':key},'rtc':{'tcp_port':7981,'node_ip':'127.0.0.1','use_external_ip':False},
                'room':{'auto_create':False,'max_participants':10}}))
            config.chmod(0o644) # Только одноразовый fixture; UID10001 должен прочитать bind mount.
            env={**os.environ,'VOICECHAT_LIVEKIT_SECRET':key,'VOICECHAT_POLICY_SECRET':secrets.token_hex(32)}
            docker('run','-d','--name',name,'--network','none','--read-only','--cap-drop','ALL',
                '--security-opt','no-new-privileges','--tmpfs','/tmp',
                '--tmpfs','/work/.prototype:uid=10001,gid=10001,mode=0700',
                '-v',str(config)+':/config/livekit.json:ro',
                '-e','VOICECHAT_LIVEKIT_SECRET','-e','VOICECHAT_POLICY_SECRET',IMAGE,env=env)
            ready=False
            for _ in range(20):
                try:
                    docker('exec',name,'python3','-c',
                        "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8090/health',timeout=1)")
                    ready=True;break
                except subprocess.CalledProcessError: time.sleep(.25)
            assert ready
            docker('exec',name,'python3','-c',
                "import sys;sys.path.insert(0,'prototype');from token_server import media_api;"
                "media_api('CreateRoom',{'name':'screen-supervisor-fixture','max_participants':2});"
                "assert media_api('ListParticipants',{'room':'screen-supervisor-fixture'}) is not None")
            docker('exec',name,'python3','-c',
                "from pathlib import Path;import os,signal;"
                "pids=[int(p.name) for p in Path('/proc').iterdir() if p.name.isdigit() and "
                "(p/'cmdline').exists() and b'prototype/token_server.py' in (p/'cmdline').read_bytes().split(b'\\0')[1:3]];"
                "assert len(pids)==1;os.kill(pids[0],signal.SIGTERM)")
            assert docker('wait',name,timeout=15)=='1'
            state=json.loads(docker('inspect',name))[0]['State']
            assert not state['Running'] and state['Pid']==0
            report.update(result='PASS',network='none, no published ports',
                healthy_control=True,real_sfu_room_created=True,control_termination_stops_entire_container=True)
    finally:
        subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False)
        report['elapsed_seconds']=time.monotonic()-start
        Path(__file__).with_name('verified-screen-supervisor-run.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))

if __name__=='__main__':
    try: main()
    except Exception as error: raise SystemExit('Screen supervisor check failed: '+type(error).__name__) from None
