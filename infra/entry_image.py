"""Pull one immutable entry image using an ephemeral repository-read bearer.

A's registry password never leaves A. The derived bearer is passed only to the
local Docker Engine for one pull; no docker login or credential file is created.
Protocol: docs.docker.com/reference/api/registry/auth/ and Moby AuthConfig's
registrytoken field (api/types/registry/authconfig.go).
"""
import base64
import http.client
import json
from pathlib import Path
import re
import socket
import subprocess
import urllib.parse
import urllib.request

import role_release
import route_health
import tls_material


def repository(image):
    if not isinstance(image, str) or not re.fullmatch(r'ghcr\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}', image):
        raise ValueError('One immutable GHCR image required')
    return image.split('@')[0].removeprefix('ghcr.io/')


def reader(image, config_file=Path('/root/.docker/config.json')):
    name = repository(image)
    headers = {}
    if config_file.exists() or config_file.is_symlink():
        raw = tls_material.read_material(config_file, private=True)
        try:
            config = json.loads(raw)
            auth = config['auths']['ghcr.io']['auth']
            decoded = base64.b64decode(auth, validate=True)
            if b':' not in decoded or not all(decoded.split(b':', 1)):
                raise ValueError('Invalid registry credential')
            headers['Authorization'] = 'Basic ' + auth
        except (KeyError, TypeError, ValueError):
            raise ValueError('A needs its existing owner-only GHCR credential; helpers are not exported') from None
    query = urllib.parse.urlencode({'service': 'ghcr.io', 'scope': 'repository:' + name + ':pull'})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), route_health.NoRedirect())
    try:
        request = urllib.request.Request('https://ghcr.io/token?' + query, headers=headers)
        with opener.open(request, timeout=30) as response:
            raw = response.read(65537)
            if response.status != 200 or len(raw) > 65536: raise ValueError('Invalid response')
        value = json.loads(raw)
        token = value.get('token', value.get('access_token'))
        expiry = value.get('expires_in', 60)
        if (not isinstance(token, str) or not token or len(token) > 32768 or
                not token.isascii() or any(c.isspace() for c in token) or
                type(expiry) is not int or not 1 <= expiry <= 3600 or
                value.get('refresh_token') or ('token' in value and 'access_token' in value and value['token'] != value['access_token'])):
            raise ValueError('Unexpected token response')
    except Exception:
        raise ValueError('Repository-read token request failed; original registry credentials remain on A') from None
    return {'token': token, 'repository': name, 'actions': ['pull'], 'expires_in': expiry}


def present(image):
    repository(image)
    result = subprocess.run(['docker', 'image', 'inspect', '--format', '{{.Id}}', image],
                            capture_output=True, timeout=30)
    return result.returncode == 0 and re.fullmatch(rb'sha256:[a-f0-9]{64}\n?', result.stdout) is not None


class Engine(http.client.HTTPConnection):
    def __init__(self):
        super().__init__('localhost', timeout=1800)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect('/var/run/docker.sock')


def pull(image, token=None):
    repository(image)
    if present(image):
        return {'schema': 1, 'image': image, 'image_ready': True, 'credential_persisted': False}
    if token is None:
        return {'schema': 1, 'image': image, 'image_ready': False, 'needs_reader': True}
    if not isinstance(token, str) or not token or len(token) > 32768 or not token.isascii() or any(c.isspace() for c in token):
        raise ValueError('Bounded repository-read bearer required')
    connection = Engine()
    auth = base64.urlsafe_b64encode(json.dumps({'serveraddress': 'ghcr.io', 'registrytoken': token}).encode()).decode()
    try:
        query = urllib.parse.urlencode({'fromImage': image})
        connection.request('POST', '/images/create?' + query, headers={'X-Registry-Auth': auth, 'Content-Length': '0'})
        response = connection.getresponse()
        if response.status != 200: raise ValueError('Image pull rejected')
        count = 0
        while True:
            line = response.readline(65537)
            if not line: break
            count += 1
            if len(line) > 65536 or count > 100000: raise ValueError('Oversized image response')
            value = json.loads(line)
            if value.get('error') or value.get('errorDetail'): raise ValueError('Registry pull failed')
    except Exception:
        raise ValueError('Immutable entry image pull failed; no credential was persisted') from None
    finally:
        connection.close()
    if not present(image):
        raise ValueError('Docker did not install the requested immutable image')
    return {'schema': 1, 'image': image, 'image_ready': True, 'credential_persisted': False}
