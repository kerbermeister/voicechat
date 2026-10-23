#!/usr/bin/env python3
"""Disposable real supervisor/SFU/control, private DB and loopback-only ports."""
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time
import traceback
from screen_status import status

IMAGE = 'voicechat-screen-control:test'


def main():
    name = 'voicechat-screen-fault-' + secrets.token_hex(6)

    def docker(*args):
        return subprocess.check_output(['docker', *args], text=True,
                                       stderr=subprocess.DEVNULL, timeout=25).strip()

    def ready():
        for _ in range(50):
            try:
                docker('exec', name, 'python3', '-c',
                       "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8090/health',timeout=1)")
                return
            except subprocess.CalledProcessError:
                time.sleep(.2)
        raise TimeoutError('Private container health')

    with tempfile.TemporaryDirectory(prefix='voicechat-screen-container-') as directory:
        root = Path(directory)
        control = root/'control'
        control.mkdir(mode=0o777)
        control.chmod(0o777)  # UID10001 owns only this disposable bind directory.
        (control/'screen-enabled').write_text('1')
        config = root/'livekit.json'
        config.write_text(json.dumps({'port': 7880, 'bind_addresses': ['0.0.0.0'],
            'keys': {'prototype': os.environ['VOICECHAT_LIVEKIT_SECRET']},
            'rtc': {'tcp_port': 7991, 'port_range_start': 50520, 'port_range_end': 50530,
                    'node_ip': '127.0.0.1', 'use_external_ip': False},
            'room': {'auto_create': False, 'max_participants': 10}}))
        config.chmod(0o644)  # Private temporary parent, read by container UID10001.
        try:
            docker('run', '-d', '--name', name, '--read-only', '--cap-drop', 'ALL',
                '--security-opt', 'no-new-privileges', '--tmpfs', '/tmp',
                '-v', f'{control}:/work/.prototype', '-v', f'{config}:/config/livekit.json:ro',
                '-p', '127.0.0.1:7882:7880', '-p', '127.0.0.1:8092:8090',
                '-p', '127.0.0.1:7991:7991', '-p', '127.0.0.1:50520-50530:50520-50530/udp',
                '-e', 'VOICECHAT_LIVEKIT_SECRET', '-e', 'VOICECHAT_POLICY_SECRET',
                '-e', 'VOICECHAT_ORIGINS',
                '-e', 'VOICECHAT_MATRIX_INTERNAL=http://host.docker.internal:8008', IMAGE)
            ready()
            ports = json.loads(docker('inspect', '--format', '{{json .NetworkSettings.Ports}}', name))
            info = {'api_port': int(ports['8090/tcp'][0]['HostPort']),
                    'livekit_url': 'ws://localhost:' + ports['7880/tcp'][0]['HostPort'],
                    'image_id': docker('inspect', '--format', '{{.Image}}', name)}
            print(json.dumps(info), flush=True)
            for line in sys.stdin:
                action = line.strip()
                extra = {}
                if action == 'restart':
                    docker('restart', name)
                    ready()
                    assert json.loads(docker('inspect', '--format', '{{json .NetworkSettings.Ports}}', name)) == ports
                elif action in ('kill_control', 'kill_sfu', 'pause_control'):
                    process = 'prototype/token_server.py' if action != 'kill_sfu' else '/usr/local/bin/livekit-server'
                    sig = 'SIGSTOP' if action == 'pause_control' else 'SIGKILL'
                    docker('exec', name, 'python3', '-c',
                        "from pathlib import Path;import os,signal;"
                        "pids=[int(p.name) for p in Path('/proc').iterdir() if p.name.isdigit() "
                        "and (p/'cmdline').exists() and " + repr(process.encode()) +
                        " in (p/'cmdline').read_bytes().split(bytes([0]))[:3]];"
                        "assert len(pids)==1;os.kill(pids[0],signal." + sig + ')')
                    extra['exit_code'] = int(docker('wait', name))
                elif action.startswith('absent '):
                    generation = action[7:]
                    assert generation.startswith('screen-') and len(generation) < 200
                    docker('exec', name, 'python3', '-c',
                        "import sys,json,time,urllib.request;sys.path.insert(0,'prototype');from token_server import jwt;"
                        "token=jwt({'iss':'prototype','exp':int(time.time())+30,'video':{'roomList':True}});"
                        "request=urllib.request.Request('http://127.0.0.1:7880/twirp/livekit.RoomService/ListRooms',"
                        "json.dumps({'names':[" + repr(generation) + "]}).encode(),"
                        "{'Authorization':'Bearer '+token,'Content-Type':'application/json'});"
                        "assert not json.load(urllib.request.urlopen(request,timeout=3)).get('rooms')")
                    extra['room_absent'] = True
                elif action == 'close':
                    break
                elif action != 'status':
                    raise ValueError('Unknown container fixture action')
                running = docker('inspect', '--format', '{{.State.Running}}', name) == 'true'
                print(json.dumps({**info, **status(control/'calls/calls.sqlite'),
                                  'running': running, **extra}), flush=True)
        finally:
            docker('rm', '-f', name)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'fixture_error': type(error).__name__,
                          'frames': [(f.name, f.lineno) for f in traceback.extract_tb(error.__traceback__)]}), file=sys.stderr)
        raise SystemExit('Screen container fixture failed: ' + type(error).__name__) from None
