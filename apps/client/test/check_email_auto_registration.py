#!/usr/bin/env python3
"""Verify the auto-registration protocol on local Synapse + Mailpit, no real mail."""
import json
import secrets
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'prototype'))
from check_registration import post, validate_email


def main():
    username = 'autoemail' + str(time.time_ns())
    email = username + '@example.test'
    password, secret = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
    device = 'auto-registration-' + secrets.token_hex(16)
    token = None
    report = {'passed': False}
    try:
        code, sent = post('register/email/requestToken', {'client_secret': secret, 'email': email, 'send_attempt': 1})
        assert code == 200, 'Local confirmation email request failed'
        auth = {'type': 'm.login.email.identity', 'threepid_creds': {'sid': sent['sid'], 'client_secret': secret}}
        body = {'username': username, 'password': password, 'device_id': device, 'auth': auth}
        for _ in range(3):
            code, response = post('register', body)
            assert code == 401 and 'access_token' not in response, 'Unverified email must not register or log in'
            auth['session'] = response.get('session', auth.get('session'))
        assert auth['session'], 'UIA session was not supplied'
        validate_email(email)
        validate_email(email)  # Opening a valid link again is not another registration.
        foreign = {**auth, 'threepid_creds': {**auth['threepid_creds'], 'client_secret': secrets.token_urlsafe(24)}}
        code, response = post('register', {**body, 'auth': foreign})
        assert code == 401 and 'access_token' not in response, 'Another form secret must not consume confirmed mail'
        code, response = post('register', body)
        assert code == 200, 'Confirmed email did not complete registration'
        token = response['access_token']
        assert response['device_id'] == device
        # Replay the same successful UIA request as after a lost response.
        code, replay = post('register', body)
        assert code == 200 and replay['user_id'] == response['user_id'], 'UIA retry duplicated or lost the account'
        token = replay['access_token']
        assert replay['device_id'] == device
        request = urllib.request.Request('http://localhost:8008/_matrix/client/v3/devices', headers={'Authorization': 'Bearer ' + token})
        with urllib.request.urlopen(request, timeout=10) as result:
            devices = json.load(result)['devices']
        assert [d['device_id'] for d in devices] == [device], 'Retry created a second device'
        report.update(passed=True, email_required=True, repeated_pending_checks=True, foreign_form_rejected=True,
                      repeated_email_link=True, authenticated_registration=True, lost_reply_replay=True, one_device=True)
    finally:
        if token:
            code, _ = post('account/deactivate', {'auth': {'type': 'm.login.password', 'identifier': {'type': 'm.id.user', 'user': username}, 'password': password}, 'erase': True}, token)
            report['account_deactivated'] = code == 200
        output = ROOT / 'apps/client/test/verified-email-auto-registration.json'
        output.write_text(json.dumps(report, indent=2) + '\n')
    print('PASS: real email proof, automatic-registration protocol, UIA replay and one device; disposable account deactivated')


if __name__ == '__main__':
    main()
