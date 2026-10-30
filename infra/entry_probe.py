"""Independent trusted-SNI checks from A before publishing an admitted entry."""
import http.client
import json
import socket
import ssl
from urllib.parse import urlsplit

import node_inventory
import route_catalog


def fetch(public, inventory, edge_id, path, maximum=65536):
    if path not in ('/health/route', '/.well-known/voicechat/routes.json'):
        raise ValueError('Only bounded public entry readiness paths are allowed')
    node_inventory.validate(inventory, public)
    edge = next(item for item in public['edges'] if item['id'] == edge_id)
    name = urlsplit(edge['origin']).hostname
    address = node_inventory.edge_assignment(inventory, edge_id)['public_ip']
    context = ssl.create_default_context(); context.minimum_version = ssl.TLSVersion.TLSv1_2
    with socket.create_connection((address, 443), timeout=10) as raw:
        with context.wrap_socket(raw, server_hostname=name) as stream:
            stream.sendall(('GET ' + path + ' HTTP/1.1\r\nHost: ' + name + '\r\nConnection: close\r\n\r\n').encode())
            response = http.client.HTTPResponse(stream); response.begin()
            body = response.read(maximum + 1)
            if response.status != 200 or len(body) > maximum:
                raise ValueError('Entry HTTPS readiness response failed')
    return body


def ready(public, inventory, edge_id):
    value = json.loads(fetch(public, inventory, edge_id, '/health/route', 4096))
    if (not isinstance(value, dict) or type(value.get('schema')) is not int or value['schema'] != 1 or
            value.get('service_id') != public['service_id'] or value.get('edge_id') != edge_id or
            value.get('matrix') is not True or value.get('control') is not True or
            type(value.get('age_ms')) is not int or not 0 <= value['age_ms'] <= 2000):
        raise ValueError('Entry route identity or upstream readiness failed')
    return {'schema': 1, 'edge_id': edge_id, 'verified_https_upstreams': True}


def catalogs(public, inventory, envelope, key, bootstrap):
    expected = route_catalog.verify(envelope, key, bootstrap)
    for edge in public['edges']:
        body = fetch(public, inventory, edge['id'], '/.well-known/voicechat/routes.json')
        actual = route_catalog.verify(body, key, bootstrap)
        if actual.payload != expected.payload:
            raise ValueError('An entry serves a different signed catalog')
    return {'schema': 1, 'revision': expected.revision, 'all_catalogs_verified': True}
