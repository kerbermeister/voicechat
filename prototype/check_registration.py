#!/usr/bin/env python3
"""Real local Synapse + Mailpit email registration/reset, no credentials in output."""
import html
from html.parser import HTMLParser
import urllib.parse
import json
import re
import secrets
import time
import urllib.error
import urllib.request
from pathlib import Path

base = 'http://localhost:8008/_matrix/client/v3/'

def post(path, body, token=None):
    request = urllib.request.Request(base + path, json.dumps(body).encode(), {'Content-Type': 'application/json', **({'Authorization': 'Bearer ' + token} if token else {})})
    try:
        with urllib.request.urlopen(request, timeout=15) as response: return response.status, json.load(response)
    except urllib.error.HTTPError as error: return error.code, json.load(error)

def validate_email(email):
    for _ in range(30):
        messages = json.load(urllib.request.urlopen('http://localhost:8025/api/v1/messages', timeout=5))['messages']
        match = next((m for m in messages if any(p['Address'] == email for p in m['To'])), None)
        if match:
            message = json.load(urllib.request.urlopen('http://localhost:8025/api/v1/message/' + match['ID'], timeout=5))
            links = re.findall(r'http://localhost:8008/[^\s<>"\']+', html.unescape(message['Text'] or message['HTML']))
            link = next(u for u in links if 'submit_token' in u)
            with urllib.request.urlopen(link, timeout=10) as response:
                assert response.status == 200
                page = response.read().decode()
            class Form(HTMLParser):
                action = link
                fields = {}
                def handle_starttag(self, tag, attrs):
                    attrs = dict(attrs)
                    if tag == 'form': self.action = urllib.parse.urljoin(link, attrs.get('action', ''))
                    if tag == 'input' and 'name' in attrs: self.fields[attrs['name']] = attrs.get('value', '')
            form = Form(); form.feed(page)
            if '<form' in page:
                assert form.action.startswith('http://localhost:8008/')
                request = urllib.request.Request(form.action, urllib.parse.urlencode(form.fields).encode())
                with urllib.request.urlopen(request, timeout=10) as response: assert response.status == 200
            return
        time.sleep(0.5)
    raise AssertionError('Verification email did not arrive')

if __name__ == '__main__':
    username = 'email' + str(int(time.time()))
    email = username + '@example.test'
    password, client_secret = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
    credentials = dict(username=username, password=password)
    code, flow = post('register', credentials)
    assert code == 401 and any('m.login.email.identity' in f['stages'] for f in flow['flows'])
    code, response = post('register/email/requestToken', dict(client_secret=client_secret, email=email, send_attempt=1))
    assert code == 200
    auth = dict(type='m.login.email.identity', session=flow['session'], threepid_creds=dict(sid=response['sid'], client_secret=client_secret))
    code, _ = post('register', dict(**credentials, auth=auth))
    assert code == 401, 'Unverified email registered'
    validate_email(email)
    code, response = post('register', dict(**credentials, auth=auth))
    assert code == 200, 'Verified registration failed'
    token = response['access_token']
    code, search = post('user_directory/search', dict(search_term=username), token)
    assert code == 200
    new_password, reset_secret = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
    # Clear only this test's mail before reset so the previous registration link cannot match.
    request = urllib.request.Request('http://localhost:8025/api/v1/search?query=to:' + email)
    previous = {m['ID'] for m in json.load(urllib.request.urlopen(request))['messages']}
    code, reset = post('account/password/email/requestToken', dict(client_secret=reset_secret, email=email, send_attempt=1))
    assert code == 200
    # The reset message must be the most recent for the recipient.
    for _ in range(30):
        messages = json.load(urllib.request.urlopen('http://localhost:8025/api/v1/messages'))['messages']
        if any(m['ID'] not in previous and any(p['Address'] == email for p in m['To']) for m in messages): break
        time.sleep(0.5)
    validate_email(email)
    code, reset_result = post('account/password', dict(new_password=new_password, logout_devices=True, auth=dict(type='m.login.email.identity', threepid_creds=dict(sid=reset['sid'], client_secret=reset_secret))))
    assert code == 200, 'Email password reset failed: ' + str(code) + ' ' + reset_result.get('errcode', '')
    code, _ = post('login', dict(type='m.login.password', identifier=dict(type='m.id.user', user=username), password=password))
    assert code == 403, 'Old password still works'
    code, login = post('login', dict(type='m.login.password', identifier=dict(type='m.id.user', user=username), password=new_password))
    assert code == 200
    post('logout', {}, login['access_token'])
    path = Path(__file__).resolve().parents[1] / '.prototype/registered-account.json'
    path.write_text(json.dumps(dict(username=username, password=new_password, email=email), indent=2))
    path.chmod(0o600)
    print('PASS: email required, verification, registration, directory query, password reset and login')
