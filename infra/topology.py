"""Public, versioned route contract. Host addresses and secrets never belong here."""
import json
import re
from pathlib import Path

from client_config import client_config


def fields(value, names):
    if not isinstance(value, dict) or set(value) != set(names):
        raise ValueError('Unexpected topology fields')


def hostname(value):
    if (not isinstance(value, str) or len(value) > 253 or
        not re.fullmatch(r'[a-z0-9]+(?:[.-][a-z0-9]+)*', value) or
        any(len(label) > 63 or label.startswith('-') or label.endswith('-')
            for label in value.split('.'))):
        raise ValueError('Canonical ASCII hostname required')
    return value


def origin(value):
    if not isinstance(value, str) or any(c.isspace() for c in value) or '?' in value or '#' in value:
        raise ValueError('Invalid origin')
    canonical = client_config(value)['MATRIX_URL']
    if canonical != value:
        raise ValueError('Canonical origin required')
    return value


def validate(value):
    fields(value, ('schema', 'service_id', 'matrix_server_name', 'canonical_origin', 'web_origins', 'edges'))
    if type(value['schema']) is not int or value['schema'] != 1:
        raise ValueError('Unsupported topology schema')
    if not isinstance(value['service_id'], str) or not re.fullmatch(r'[a-z][a-z0-9-]{0,62}', value['service_id']):
        raise ValueError('Invalid service ID')
    hostname(value['matrix_server_name'])
    canonical = origin(value['canonical_origin'])
    web = value['web_origins']
    if not isinstance(web, list) or not 1 <= len(web) <= 33 or len(set(map(origin, web))) != len(web) or canonical not in web:
        raise ValueError('Invalid web origins')
    edges = value['edges']
    if not isinstance(edges, list) or not 1 <= len(edges) <= 32:
        raise ValueError('Between 1 and 32 edges required')
    for edge in edges:
        fields(edge, ('id', 'origin', 'turn_host'))
        if not isinstance(edge['id'], str) or not re.fullmatch(r'[a-z][a-z0-9-]{0,31}', edge['id']):
            raise ValueError('Invalid edge ID')
        origin(edge['origin'])
        hostname(edge['turn_host'])
        if edge['origin'].split(':', 1)[0] != canonical.split(':', 1)[0]:
            raise ValueError('Mixed route schemes')
    for key in ('id', 'origin', 'turn_host'):
        if len({edge[key] for edge in edges}) != len(edges):
            raise ValueError('Duplicate edge ' + key)
    return value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON field')
        result[key] = value
    return result


def read_json(path):
    with Path(path).open('rb') as source:
        raw = source.read(65537)
    if len(raw) > 65536: raise ValueError('Oversized configuration document')
    return json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object)


def load(path):
    return validate(read_json(path))


def client_defines(value):
    validate(value)
    return {**client_config(value['canonical_origin']),
            'ROUTE_CONFIG': json.dumps(value, separators=(',', ':'), sort_keys=True)}
