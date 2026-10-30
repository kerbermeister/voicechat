"""Keep a signed public catalog separate from the bounded operation settings."""
import hashlib
import json
from pathlib import Path

import managed_state
import role_release
import route_catalog
import topology


def normalize(value):
    if not isinstance(value, dict) or not isinstance(value.get('catalog'), str):
        raise ValueError('Signed catalog settings required')
    raw = value['catalog'].encode()
    if len(raw) > route_catalog.MAX_ENVELOPE:
        raise ValueError('Oversized signed catalog')
    envelope = json.loads(raw, object_pairs_hook=topology.unique_object)
    topology.fields(envelope, ('payload', 'signature'))
    catalog = json.dumps(envelope, sort_keys=True, separators=(',', ':'))
    return {**value, 'catalog': catalog}


def load(directory):
    directory = Path(directory)
    if directory.resolve() != directory or not directory.is_dir() or directory.stat().st_mode & 0o077:
        raise ValueError('Canonical private operation settings directory required')
    value = managed_state.read(directory / 'settings.json')
    topology.fields(value, ('schema', 'settings', 'catalog_sha256'))
    if type(value['schema']) is not int or value['schema'] != 1 or not isinstance(value['settings'], dict) or 'catalog' in value['settings']:
        raise ValueError('Known operation settings index required')
    catalog = json.dumps(managed_state.read(directory / 'catalog.json'), sort_keys=True, separators=(',', ':'))
    if hashlib.sha256(catalog.encode()).hexdigest() != value['catalog_sha256']:
        raise ValueError('Frozen signed catalog changed')
    return normalize({**value['settings'], 'catalog': catalog})


def store(directory, value):
    value = normalize(value)
    with managed_state.locked(directory) as root:
        metadata = root / 'settings.json'
        if metadata.exists() or metadata.is_symlink():
            if load(root) != value:
                raise ValueError('Resume the original operation settings')
        else:
            catalog = root / 'catalog.json'
            expected = json.loads(value['catalog'])
            if catalog.exists() or catalog.is_symlink():
                if managed_state.read(catalog) != expected:
                    raise ValueError('Unclaimed operation catalog differs')
            else:
                managed_state.persist(catalog, expected)
            managed_state.persist(metadata, {'schema': 1,
                'settings': {key: item for key, item in value.items() if key != 'catalog'},
                'catalog_sha256': hashlib.sha256(value['catalog'].encode()).hexdigest()})
    return role_release.json_digest(value)
