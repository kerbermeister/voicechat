"""Small, validated edge configuration renderers; no host/DNS side effects."""
from topology import hostname


def shared_legacy_proxy(business_routes, public, edge_id, ingress_ip):
    """Keep business routes and HTTP-01 certificate management behind shared SNI.

    Input is the reviewed business Caddyfile, excluding previous VoiceChat routes.
    Validate the result with the pinned Caddy before replacing any live config.
    """
    import re
    from urllib.parse import urlsplit
    from node_inventory import ipv4
    from topology import validate
    validate(public)
    ipv4(ingress_ip, tunnel=True)
    if (not isinstance(business_routes, str) or not business_routes.strip() or
            len(business_routes.encode()) > 65536 or '\0' in business_routes or
            re.search(r'(?m)^\s*\{(?:\s|$)', business_routes)):
        raise ValueError('Reviewed business routes without global options required')
    edge = next((item for item in public['edges'] if item['id'] == edge_id), None)
    if edge is None: raise ValueError('Unknown shared edge')
    origins = (public['canonical_origin'], edge['origin'])
    if any(urlsplit(origin).scheme != 'https' or urlsplit(origin).port not in (None, 443) for origin in origins):
        raise ValueError('Shared TLS requires standard HTTPS origins')
    names = sorted({*(urlsplit(origin).hostname for origin in origins), edge['turn_host']})
    if any(name in business_routes for name in names):
        raise ValueError('Remove previous VoiceChat routes from the business source')
    return f'''{{
    servers :443 {{
        protocols h1 h2
        strict_sni_host on
        listener_wrappers {{
            proxy_protocol {{
                timeout 2s
                allow {ingress_ip}/32
                fallback_policy reject
            }}
            tls
        }}
    }}
}}
{business_routes.rstrip()}

{', '.join(names)} {{
    tls {{
        issuer acme {{
            disable_tlsalpn_challenge
        }}
    }}
    respond 421
}}
'''


def sni_proxy(web_hosts, turn_host, *, web_ip=None, turn_ip=None, legacy_ip=None):
    names = sorted(set(map(hostname, web_hosts)))
    turn_host = hostname(turn_host)
    if not names or turn_host in names:
        raise ValueError('Separate HTTPS and TURN names required')
    if (web_ip is None) != (turn_ip is None):
        raise ValueError('Both fixed proxy backends are required')
    if web_ip is not None:
        from node_inventory import ipv4
        ipv4(web_ip, tunnel=True)
        ipv4(turn_ip, tunnel=True)
    if legacy_ip is not None:
        from node_inventory import ipv4
        ipv4(legacy_ip, tunnel=True)
    reject = '    tcp-request content reject if client_hello !web_name !turn_name\n' if legacy_ip is None else ''
    fallback = '' if legacy_ip is None else '    default_backend legacy_tls\n'
    # TLS stays end-to-end between the client and Caddy/coturn. No custom TLS parser.
    return f'''global
    maxconn 4096

defaults
    mode tcp
    timeout connect 5s
    timeout client 1h
    timeout server 1h

resolvers containers
    parse-resolv-conf
    hold valid 5s
    hold nx 1s
    hold timeout 1s
    timeout resolve 1s
    timeout retry 1s

frontend tls
    bind :8443
    tcp-request inspect-delay 5s
    acl client_hello req.ssl_hello_type 1
    acl web_name req.ssl_sni -i {' '.join(names)}
    acl turn_name req.ssl_sni -i {turn_host}
{reject}    tcp-request content accept if client_hello
    use_backend web_tls if web_name
    use_backend turn_tls if turn_name
{fallback}
backend web_tls
    server web {web_ip or 'web'}:8443 check send-proxy-v2 resolvers containers init-addr libc,none

backend turn_tls
    server turn {turn_ip or 'turn'}:5349 check resolvers containers init-addr libc,none
''' + (f'\nbackend legacy_tls\n    server legacy {legacy_ip}:443 check send-proxy-v2\n' if legacy_ip else '')


def edge_proxy(topology, edge_id, core_ip, ingress_ip):
    """Reuse the existing public-route policy; add an exact CORS boundary."""
    import ipaddress
    from pathlib import Path
    from urllib.parse import urlsplit
    from topology import validate
    validate(topology)
    core = ipaddress.ip_address(core_ip)
    ingress = ipaddress.ip_address(ingress_ip)
    private_ranges = [ipaddress.ip_network(value) for value in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')]
    if any(address.version != 4 or not any(address in network for network in private_ranges)
           for address in (core, ingress)):
        raise ValueError('Private IPv4 tunnel and ingress addresses required')
    edge = next((item for item in topology['edges'] if item['id'] == edge_id), None)
    if edge is None: raise ValueError('Unknown edge')
    names = sorted({urlsplit(edge['origin']).hostname, urlsplit(topology['canonical_origin']).hostname})
    if any(urlsplit(origin).scheme != 'https' or urlsplit(origin).port not in (None, 443)
           for origin in [edge['origin'], topology['canonical_origin']]):
        raise ValueError('Edge TLS requires standard HTTPS origins')
    source = Path(__file__).with_name('Caddyfile').read_text()
    _, separator, body = source.partition('{$SITE} {')
    if not separator: raise ValueError('Public route template changed; review edge rendering')
    global_options = f'''{{
    admin off
    auto_https off
    persist_config off
    log default {{
        exclude http.log.error http.log.access
    }}
    servers :8443 {{
        protocols h1 h2
        strict_sni_host on
        listener_wrappers {{
            proxy_protocol {{
                timeout 2s
                allow {ingress}/32
                fallback_policy reject
            }}
            tls
        }}
    }}
}}
'''
    origins = '\n'.join('        header Origin ' + origin for origin in topology['web_origins'])
    boundary = f'''
    tls /tls/web.crt /tls/web.key
    @foreign_origin {{
        header Origin *
        not {{
{origins}
        }}
    }}
    @allowed_origin {{
{origins}
    }}
    @preflight {{
        method OPTIONS
{origins}
    }}
    header @allowed_origin {{
        Access-Control-Allow-Origin {{header.Origin}}
        +Vary Origin
        Access-Control-Allow-Methods "GET, HEAD, POST, PUT, DELETE, OPTIONS"
        Access-Control-Allow-Headers "Authorization, Content-Type, Range, If-Range, If-Match, If-None-Match, Cache-Control"
        Access-Control-Expose-Headers "Content-Length, Content-Range, ETag, Retry-After"
    }}
'''
    boundary_marker = '    route {\n    respond @private 404'
    if body.count(boundary_marker) != 1:
        raise ValueError('Public route boundary changed; review edge rendering')
    body = body.replace(boundary_marker, '''    route {
    respond @private 404
    respond @foreign_origin 403
    respond @preflight 204
    handle /.well-known/voicechat/routes.json {
        root * /catalog
        rewrite * /routes.json
        header Cache-Control no-store
        file_server
    }
    handle /health/route {
        reverse_proxy route-health:8091
    }''', 1)
    for old, port in (('synapse:8008', 8088), ('control:8090', 8090), ('control:7880', 7880)):
        if 'reverse_proxy ' + old not in body:
            raise ValueError('Upstream template changed; review edge rendering')
        body = body.replace('reverse_proxy ' + old, f'''reverse_proxy {core}:{port} {{
            header_up -Forwarded
            header_up X-Forwarded-For {{remote_host}}
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {{host}}
            header_down -Access-Control-Allow-Origin
            header_down -Access-Control-Allow-Credentials
        }}''')
    return global_options + ' '.join('https://' + name + ':8443' for name in names) + ' {' + boundary + body
