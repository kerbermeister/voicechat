"""Initialize private configuration inside named volumes; preserve signing/media data."""
import json
import base64
import os
from pathlib import Path


def write(path, value, uid):
    path=Path(path)
    path.parent.mkdir(parents=True,exist_ok=True)
    os.chown(path.parent,uid,uid)
    path.parent.chmod(0o700)
    path.write_text(value)
    os.chown(path,uid,uid)
    path.chmod(0o600)


def configure_policy(defaults=Path('/client-policy.json'), target=Path('/media/client-policy.json')):
    value = json.loads(defaults.read_text())
    if target.exists(): value.update(json.loads(target.read_text()))
    write(target, json.dumps(value), 10001)


def main():
    env=os.environ
    local=env['LOCAL_STAND']=='1'
    name=env['MATRIX_SERVER_NAME']
    marker=Path('/matrix/.voicechat-server-name')
    if marker.exists() and marker.read_text()!=name: raise SystemExit('Refusing a Matrix server_name change on existing data')
    sender = (base64.b64decode(env['SMTP_FROM_B64'], validate=True).decode()
              if env.get('SMTP_FROM_B64') else f'VoiceChat <noreply@{name}>')
    if not sender.strip() or '\r' in sender or '\n' in sender:
        raise ValueError('SMTP_FROM must be a nonempty single-line sender')
    smtp={'smtp_host':env['SMTP_HOST'],'smtp_port':int(env['SMTP_PORT']),
        'require_transport_security':not local,'enable_tls':not local,
        'notif_from':sender,'app_name':'VoiceChat'}
    if env.get('SMTP_USER_B64'):
        smtp.update(smtp_user=base64.b64decode(env['SMTP_USER_B64'],validate=True).decode(),
                    smtp_pass=base64.b64decode(env['SMTP_PASSWORD_B64'],validate=True).decode())
    synapse={
        'server_name':name,'public_baseurl':env['PUBLIC_URL']+'/', 'enable_ephemeral_messages':True,
        'modules':[{'module':'voicechat_policy.ContactPolicy','config':{'url':'http://control:8090/internal/contact-authorized','secret':env['POLICY_SECRET']}}],
        'listeners':[{'port':8008,'type':'http','tls':False,'bind_addresses':['0.0.0.0'],
                      'x_forwarded':True,'resources':[{'names':['client'],'compress':False}]}],
        'database':{'name':'psycopg2','args':{'user':'synapse','password':env['POSTGRES_PASSWORD'],
                     'database':'synapse','host':'postgres','cp_min':2,'cp_max':5}},
        'media_store_path':'/data/media_store','signing_key_path':'/data/voicechat.signing.key',
        'registration_shared_secret':env['REGISTRATION_SECRET'],'macaroon_secret_key':env['MACAROON_SECRET'],
        'experimental_features':{'msc2654_enabled':True},'enable_registration':True,
        'registrations_require_3pid':['email'],'enable_registration_without_verification':False,'email':smtp,
        'user_directory':{'search_all_users':True},'turn_uris':[f"turn:{env['PUBLIC_IP']}:3488?transport=tcp",f"turn:{env['PUBLIC_IP']}:3488?transport=udp"],
        'turn_shared_secret':env['TURN_SECRET'],'turn_user_lifetime':'1h','turn_allow_guests':False,
        'report_stats':False,'trusted_key_servers':[],'federation_domain_whitelist':[], 'max_upload_size':'350M',
    }
    if local:
        synapse['rc_login'] = {kind: {'per_second': 20, 'burst_count': 100}
                               for kind in ('address', 'account')}
    write('/matrix/homeserver.yaml',json.dumps(synapse),991)
    write(marker,name,991)
    configure_policy()
    write('/media/livekit.json',json.dumps({'port':7880,'bind_addresses':['0.0.0.0'],
        'rtc':{'tcp_port':7981,'port_range_start':50300,'port_range_end':50400,'use_external_ip':False,'node_ip':env['PUBLIC_IP']},
        'keys':{'prototype':env['LIVEKIT_SECRET']},'room':{'auto_create':False,'max_participants':10}}),10001)
    turn=f"listening-port=3488\nfingerprint\nuse-auth-secret\nstatic-auth-secret={env['TURN_SECRET']}\nrealm={name}\nmin-port=49300\nmax-port=49400\ncli=off\nno-tls\nno-dtls\nno-multicast-peers\nexternal-ip={env['PUBLIC_IP']}\n"
    if local: turn+='allow-loopback-peers\n'
    else:
        for subnet in ('0.0.0.0-0.255.255.255','10.0.0.0-10.255.255.255','127.0.0.0-127.255.255.255','169.254.0.0-169.254.255.255','172.16.0.0-172.31.255.255','192.168.0.0-192.168.255.255','::1','fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff'):
            turn+='denied-peer-ip='+subnet+'\n'
    write('/turn/turnserver.conf',turn,10001)


if __name__=='__main__': main()
