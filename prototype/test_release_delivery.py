import fcntl
import gzip
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'infra'))
import release_delivery as delivery


class ImmutableSourceDeliveryTests(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup)
        self.base=Path(temporary.name).resolve();self.root=self.base/'managed'
        self.commit='a'*40
        self.manifest={'schema':1,'commit':self.commit,'origin':'https://chat.example.invalid',
            'control':'ghcr.io/fixture/control@sha256:'+'1'*64,'web':'ghcr.io/fixture/web@sha256:'+'2'*64}
        self.files={name:b'# fixture public source\n' for name in
            ('infra/initial_cohost.py','infra/core_deploy.py','infra/edge_deploy.py','infra/role_release.py','infra/release_delivery.py')}
        self.files.update({'prototype/'+name:b'{}\n' for name in delivery.POLICIES})
        self.files.update({'release.json':json.dumps(self.manifest).encode(),'backend.sha256':b'b'*64+b'\n'})

    def archive(self,extra=()):
        output=io.BytesIO()
        with tarfile.open(fileobj=output,mode='w') as archive:
            for name,raw in self.files.items():
                info=tarfile.TarInfo(name);info.size=len(raw)
                archive.addfile(info,io.BytesIO(raw))
            for info,raw in extra:archive.addfile(info,None if raw is None else io.BytesIO(raw))
        raw=gzip.compress(output.getvalue(),mtime=0)
        return raw,hashlib.sha256(raw).hexdigest()

    def install(self,raw,sha):return delivery.install(raw,self.root,sha,self.commit)

    def test_optional_guard_is_bound_to_metadata_bytes_and_cannot_be_relabelled(self):
        self.files['core-scope.sha256'] = b'7' * 64 + b'\n'
        raw, sha = self.archive();target = self.install(raw, sha)
        record = json.loads((target/'delivery.json').read_text())
        self.assertEqual(record['core_guard'], '7' * 64)
        changed = {**record, 'core_guard': '8' * 64}
        (target/'delivery.json').write_text(json.dumps(changed))
        with self.assertRaisesRegex(ValueError, 'verified files'):
            delivery.verify(target, changed)
        self.files['core-scope.sha256'] = b'not-a-hash'
        raw, sha = self.archive()
        with self.assertRaisesRegex(ValueError, 'source guard'):
            delivery.unpack(raw, sha, self.commit)

    def test_repeat_verifies_exact_existing_source_without_overwrite(self):
        raw,sha=self.archive();target=self.install(raw,sha)
        self.assertEqual(target,self.root/'bundles'/sha)
        before={path:path.stat().st_ino for path in target.rglob('*')}
        self.assertEqual(self.install(raw,sha),target)
        self.assertEqual(before,{path:path.stat().st_ino for path in target.rglob('*')})
        record=json.loads((target/'delivery.json').read_text())
        self.assertEqual(record['backend'],'b'*64)
        self.assertEqual(record['manifest'],self.manifest)
        self.assertEqual(set(record['files']),set(self.files))

    def test_bad_checksum_is_rejected_before_creating_managed_root(self):
        raw,sha=self.archive()
        with self.assertRaisesRegex(ValueError,'checksum'):self.install(raw,'0'*64)
        self.assertFalse(self.root.exists())
        with self.assertRaisesRegex(ValueError,'identities'):delivery.install(raw,self.root,sha,'not-a-commit')
        self.assertFalse(self.root.exists())

    def test_traversal_links_duplicate_and_runtime_entries_cannot_be_extracted(self):
        outside=self.base/'private-data';outside.write_bytes(b'preserve data')
        for name,kind in (('../private-data',tarfile.REGTYPE),('infra/../private-data',tarfile.REGTYPE),
                          ('infra/link.py',tarfile.SYMTYPE),('infra/link.py',tarfile.LNKTYPE),
                          ('infra/runtime/stand.env',tarfile.REGTYPE),('release.json',tarfile.REGTYPE)):
            with self.subTest(name=name,kind=kind):
                info=tarfile.TarInfo(name);info.type=kind
                if kind==tarfile.REGTYPE:info.size=1;content=b'x'
                else:info.linkname=str(outside);content=None
                raw,sha=self.archive([(info,content)])
                with self.assertRaises(ValueError):self.install(raw,sha)
                self.assertFalse(self.root.exists());self.assertEqual(outside.read_bytes(),b'preserve data')

    def test_changed_or_extra_source_file_is_never_replaced_on_retry(self):
        raw,sha=self.archive();target=self.install(raw,sha)
        source=target/'infra/core_deploy.py';source.write_bytes(b'foreign source')
        with self.assertRaisesRegex(ValueError,'file changed'):self.install(raw,sha)
        self.assertEqual(source.read_bytes(),b'foreign source')
        source.write_bytes(self.files['infra/core_deploy.py'])
        shadow=target/'infra/json.py';shadow.write_bytes(b'foreign module')
        with self.assertRaisesRegex(ValueError,'file set'):self.install(raw,sha)
        self.assertEqual(shadow.read_bytes(),b'foreign module')

    def test_compression_bomb_is_bounded_before_any_filesystem_mutation(self):
        raw=gzip.compress(b'0'*(delivery.MAX_SOURCE+1),mtime=0)
        with self.assertRaisesRegex(ValueError,'too large'):
            self.install(raw,hashlib.sha256(raw).hexdigest())
        self.assertFalse(self.root.exists())

    def test_invalid_manifest_and_source_fingerprint_are_not_published(self):
        for key,value in (('schema',True),('commit','c'*40),('origin','https://user:password@example.invalid'),('origin','https://@example.invalid')):
            with self.subTest(key=key):
                manifest={**self.manifest,key:value};self.files['release.json']=json.dumps(manifest).encode()
                raw,sha=self.archive()
                with self.assertRaises(ValueError):self.install(raw,sha)
                self.assertFalse(self.root.exists())
        self.files['release.json']=json.dumps(self.manifest).encode();self.files['backend.sha256']=b'not a fingerprint'
        raw,sha=self.archive()
        with self.assertRaisesRegex(ValueError,'fingerprint'):self.install(raw,sha)
        self.assertFalse(self.root.exists())

    def test_symlinked_target_and_concurrent_installer_preserve_existing_data(self):
        raw,sha=self.archive();target=self.install(raw,sha)
        with (self.root/'bundles/.install.lock').open('r+') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):self.install(raw,sha)
        moved=self.base/'existing-source';target.rename(moved);target.symlink_to(moved,target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'symlink'):self.install(raw,sha)
        self.assertEqual((moved/'infra/core_deploy.py').read_bytes(),self.files['infra/core_deploy.py'])


if __name__=='__main__':unittest.main()
