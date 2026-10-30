"""Standalone read-only build hints from the typed managed pointer.

These hashes/digests select artifacts; they are not proof of running services.
The deployment coordinator still checks every actual role before beginning.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

SHA=re.compile(r'[a-f0-9]{64}')
IMAGE=re.compile(r'ghcr\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}')


def unique(pairs):
    result={}
    for key,value in pairs:
        if key in result:raise ValueError('Duplicate managed metadata key')
        result[key]=value
    return result


def read(path):
    descriptor=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(descriptor,'rb') as stream:
        info=os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid() or info.st_mode&0o022:
            raise ValueError('Owned regular managed metadata required')
        raw=stream.read(65537)
    if len(raw)>65536:raise ValueError('Managed metadata exceeds its bound')
    return raw,json.loads(raw.decode('utf-8'),object_pairs_hook=unique)


def digest(value):return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def hints(root):
    root=Path(root).absolute()
    if (root.resolve()!=root or root==Path('/') or not re.fullmatch(r'/[A-Za-z0-9/_-]+',str(root)) or
            not root.is_dir() or root.stat().st_uid!=os.geteuid() or root.stat().st_mode&0o077):
        raise ValueError('Existing private canonical managed root required')
    before,current=read(root/'current.json')
    if type(current.get('schema')) is not int or current['schema']!=1:raise ValueError('Typed managed pointer required')
    if current.get('kind')=='roles':
        _,initial=read(root/'initial.json');target=current['target']
        if initial['phase']!='complete' or initial['target']!=target or target['root']!=str(root):
            raise ValueError('Complete initial role adoption required')
        baseline={'schema':1,'backend':target['backend_sha256'],'public':target['public'],
                  'inventory':target['inventory'],'subnet':target['subnet'],'core':target['core'],
                  'edges':{target['edge']['edge_id']:target['edge']}}
    elif current.get('kind')=='managed':
        directory=root/'baselines'
        if directory.resolve()!=directory or not directory.is_dir():raise ValueError('Canonical baseline store required')
        def object_(checksum):
            if not isinstance(checksum,str) or not SHA.fullmatch(checksum):raise ValueError('Baseline object digest required')
            _,value=read(directory/(checksum+'.json'))
            if digest(value)!=checksum:raise ValueError('Baseline object changed')
            return value
        index=object_(current['baseline'])
        version=index.get('schema')
        fields={'schema','backend','public','inventory','subnet','core','edges'}
        if version==2:fields.add('core_guard')
        if set(index)!=fields or type(version) is not int or version not in (1,2):
            raise ValueError('Known baseline index required')
        if version==2 and (not isinstance(index['core_guard'],str) or not SHA.fullmatch(index['core_guard'])):
            raise ValueError('Recorded core source guard required')
        if not isinstance(index['edges'],dict) or not 1<=len(index['edges'])<=32:raise ValueError('Bounded edge baseline required')
        baseline={**index,**{key:object_(index[key]) for key in ('public','inventory','core')},
                  'edges':{key:object_(value) for key,value in index['edges'].items()}}
    else:raise ValueError('Finish migration before using managed build hints')
    backend=baseline['backend'];control=baseline['core']['images']['control']
    web={key:manifest['images']['web'] for key,manifest in baseline['edges'].items()}
    if (not isinstance(backend,str) or not SHA.fullmatch(backend) or not isinstance(control,str) or not IMAGE.fullmatch(control) or
            not web or len(web)>32 or any(not re.fullmatch(r'[a-z][a-z0-9-]{0,31}',key) or
            not isinstance(value,str) or not IMAGE.fullmatch(value) for key,value in web.items())):
        raise ValueError('Immutable build digests required')
    pending=None;path=root/'rollout.json'
    if path.exists() or path.is_symlink():
        _,journal=read(path)
        pending={key:journal[key] for key in ('attempt','phase')}
        pending['source']=journal['request']['source']
        if (any(not isinstance(pending[key],str) or not SHA.fullmatch(pending[key]) for key in ('attempt','source')) or
                pending['phase'] not in ('fencing','applying','verifying','committing','releasing','complete',
                                         'rolling-back','rollback-verifying','rollback-releasing','rolled-back')):
            raise ValueError('Known release resume hint required')
    if read(root/'current.json')[0]!=before:raise ValueError('Managed pointer changed during build hint read')
    result={'schema':1,'baseline':digest(baseline),'backend':backend,'origin':baseline['public']['canonical_origin'],
            'control':control,'web':web,'pending':pending,'core_guard':baseline.get('core_guard')}
    if len(json.dumps(result).encode())>65536:raise ValueError('Build hint response exceeds its bound')
    return result


def main():
    if sys.platform!='linux' or os.geteuid()!=0 or len(sys.argv)!=2:
        raise ValueError('Read hints from the pinned Linux data host as root')
    print(json.dumps(hints(Path(sys.argv[1]))))


if __name__=='__main__':main()
