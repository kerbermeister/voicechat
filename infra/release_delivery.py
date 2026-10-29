"""Receive a bounded immutable CI source bundle through pinned SSH stdin.

Standalone stdlib bootstrap: safe to copy to a private temporary directory before
any project modules are installed. It stages public sources, never runtime/data.
"""
import argparse
import fcntl
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tarfile
import tempfile
from urllib.parse import urlsplit

SHA=re.compile(r'[a-f0-9]{64}')
COMMIT=re.compile(r'[a-f0-9]{40}')
IMAGE=re.compile(r'ghcr\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}')
MAX_COMPRESSED=8*1024**2
MAX_SOURCE=16*1024**2
MAX_FILE=1024**2
POLICIES={'voicechat_policy.py','client_policy.py','scheduled_messages.py','client-policy.json'}


def unique(pairs):
    value={}
    for key,item in pairs:
        if key in value:raise ValueError('Duplicate source metadata key')
        value[key]=item
    return value


def decode(raw):return json.loads(raw.decode('utf-8'),object_pairs_hook=unique)


def unpack(raw, expected_sha, commit):
    if not isinstance(expected_sha,str) or not SHA.fullmatch(expected_sha) or not isinstance(commit,str) or not COMMIT.fullmatch(commit):
        raise ValueError('Exact immutable archive and Git identities required')
    if len(raw)>MAX_COMPRESSED or hashlib.sha256(raw).hexdigest()!=expected_sha:
        raise ValueError('Source archive checksum/size mismatch')
    with gzip.GzipFile(fileobj=io.BytesIO(raw)) as stream:plain=stream.read(MAX_SOURCE+1)
    if len(plain)>MAX_SOURCE:raise ValueError('Uncompressed source bundle is too large')
    files={};seen=set()
    with tarfile.open(fileobj=io.BytesIO(plain),mode='r:') as archive:
        for number,item in enumerate(archive,1):
            if number>256:raise ValueError('Too many source archive entries')
            path=PurePosixPath(item.name);name=path.as_posix()
            if item.name.rstrip('/')!=name or path.is_absolute() or name in seen:
                raise ValueError('Noncanonical or duplicate source path')
            seen.add(name)
            if item.isdir():
                if name not in ('infra','prototype'):raise ValueError('Unexpected source directory')
                continue
            if not item.isfile() or item.issparse() or not 0<=item.size<=MAX_FILE:
                raise ValueError('Only bounded regular source files are allowed')
            allowed=(name in ('release.json','backend.sha256') or
                (len(path.parts)==2 and path.parts[0]=='infra' and
                 re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}',path.name) and
                 path.name not in ('runtime','__pycache__')) or
                (len(path.parts)==2 and path.parts[0]=='prototype' and path.name in POLICIES))
            if not allowed:raise ValueError('Runtime, nested or unknown source archive entry')
            stream=archive.extractfile(item)
            content=stream.read(MAX_FILE+1)
            if len(content)!=item.size:raise ValueError('Truncated source member')
            files[name]=content
    required={'release.json','backend.sha256','infra/initial_cohost.py','infra/core_deploy.py',
              'infra/edge_deploy.py','infra/role_release.py','infra/release_delivery.py',*('prototype/'+name for name in POLICIES)}
    if not required<=files.keys():raise ValueError('Incomplete deployment source bundle')
    manifest=decode(files['release.json'])
    if (not isinstance(manifest,dict) or set(manifest)!= {'schema','commit','origin','control','web'} or
            type(manifest['schema']) is not int or manifest['schema']!=1 or manifest['commit']!=commit or
            not isinstance(manifest['origin'],str) or
            any(not isinstance(manifest[key],str) or not IMAGE.fullmatch(manifest[key]) for key in ('control','web'))):
        raise ValueError('Invalid immutable candidate manifest')
    origin=urlsplit(manifest['origin'])
    if (origin.scheme!='https' or not origin.hostname or origin.username is not None or origin.password is not None or
            origin.path not in ('','/') or origin.query or origin.fragment):
        raise ValueError('Canonical HTTPS candidate origin required')
    backend=files['backend.sha256'].decode('ascii').strip()
    if not SHA.fullmatch(backend):raise ValueError('Build-generated backend fingerprint required')
    record={'schema':1,'archive_sha256':expected_sha,'manifest':manifest,'backend':backend,
            'files':{name:hashlib.sha256(content).hexdigest() for name,content in files.items()}}
    if len(json.dumps(record).encode())>65536:raise ValueError('Source receipt is too large')
    return files,record


def directory(path):
    path.mkdir(mode=0o700,exist_ok=True)
    info=path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.geteuid() or info.st_mode&0o077:
        raise ValueError('Owned private source directory required')


def read(path):
    descriptor=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(descriptor,'rb') as stream:
        info=os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid() or info.st_mode&0o022:
            raise ValueError('Owned regular source file required')
        raw=stream.read(MAX_FILE+1)
    if len(raw)>MAX_FILE:raise ValueError('Oversized stored source')
    return raw


def sync(path):
    descriptor=os.open(path,os.O_RDONLY|os.O_DIRECTORY)
    try:os.fsync(descriptor)
    finally:os.close(descriptor)


def verify(path, record):
    if decode(read(path/'delivery.json'))!=record:raise ValueError('Existing source belongs to another delivery')
    allowed=set(record['files'])|{'delivery.json'}
    actual=set()
    for item in path.rglob('*'):
        if item.is_symlink():raise ValueError('Immutable source must not contain symlinks')
        if item.is_dir():
            info=item.stat()
            if info.st_uid!=os.geteuid() or info.st_mode&0o077:
                raise ValueError('Immutable source directory ownership changed')
            if item.relative_to(path).as_posix() not in ('infra','prototype'):
                raise ValueError('Unexpected immutable source directory')
        else:actual.add(item.relative_to(path).as_posix())
    if actual!=allowed:raise ValueError('Immutable source file set changed')
    for name,checksum in record['files'].items():
        if hashlib.sha256(read(path/name)).hexdigest()!=checksum:
            raise ValueError('Immutable source file changed')


def install(raw, root, expected_sha, commit):
    files,record=unpack(raw,expected_sha,commit)
    root=Path(root)
    if not root.is_absolute() or root.resolve()!=root or not re.fullmatch(r'/[A-Za-z0-9_./-]+',str(root)):
        raise ValueError('Canonical absolute source installation root required')
    directory(root);bundles=root/'bundles';directory(bundles)
    descriptor=os.open(bundles/'.install.lock',os.O_WRONLY|os.O_CREAT|os.O_NOFOLLOW|os.O_NONBLOCK,0o600)
    with os.fdopen(descriptor,'w') as lock:
        info=os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid() or info.st_mode&0o077:
            raise ValueError('Private source install lock required')
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        target=bundles/expected_sha
        if target.exists() or target.is_symlink():
            if target.resolve()!=target:raise ValueError('Immutable source root must not be a symlink')
            directory(target);verify(target,record)
            return target
        with tempfile.TemporaryDirectory(prefix='.source-',dir=bundles) as temporary:
            stage=Path(temporary)/'bundle';stage.mkdir(mode=0o700)
            for name,content in {**files,'delivery.json':(json.dumps(record,sort_keys=True)+'\n').encode()}.items():
                destination=stage/name
                if destination.parent!=stage:destination.parent.mkdir(mode=0o700,exist_ok=True)
                with destination.open('xb') as output:
                    os.fchmod(output.fileno(),0o600 if name=='delivery.json' else 0o644)
                    output.write(content);output.flush();os.fsync(output.fileno())
            for folder in ('infra','prototype'):sync(stage/folder)
            sync(stage);stage.rename(target);sync(bundles)
        verify(target,record)
        return target


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--sha256',required=True)
    parser.add_argument('--commit',required=True)
    args=parser.parse_args()
    raw=sys.stdin.buffer.read(MAX_COMPRESSED+1)
    path=install(raw,args.root,args.sha256,args.commit)
    print(json.dumps({'schema':1,'path':str(path),'archive_sha256':args.sha256}))


if __name__=='__main__':main()
