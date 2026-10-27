"""Execute the production policy class with a small Synapse API double."""
import ast
import unittest
from pathlib import Path
from types import SimpleNamespace
from collections.abc import Mapping
from unittest.mock import AsyncMock

# Synapse is installed in its server image, not the developer Python runtime.
# Load the actual hooks unchanged; imported server classes are not exercised here.
source = ast.parse(Path(__file__).with_name('voicechat_policy.py').read_text())
nodes = [node for node in source.body if
         isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id in ('KIND', 'PERSONAL') for t in node.targets)
         or isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in ('personal_owner', 'ContactPolicy')]
NOT_SPAM = object()
namespace = {'Mapping': Mapping, 'NOT_SPAM': NOT_SPAM, 'Codes': SimpleNamespace(FORBIDDEN='forbidden')}
exec(compile(ast.Module(body=nodes, type_ignores=[]), 'voicechat_policy.py', 'exec'), namespace)
ContactPolicy = namespace['ContactPolicy']

class PersonalPolicyTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.owner = '@owner:local'
        self.creation = SimpleNamespace(sender=self.owner, content={'type': 'dev.voicechat.personal'}, event_id='$create')
        self.state = {('m.room.create', ''): self.creation}
        self.policy = object.__new__(ContactPolicy)
        self.policy.state = AsyncMock(return_value=self.state)
    def event(self, kind, sender=None, key='', content=None, **kwargs):
        return SimpleNamespace(type=kind, sender=sender or self.owner, state_key=key, content=content or {}, **kwargs)
    async def allowed(self, event):
        return (await self.policy.check_event_allowed(event, self.state))[0]
    async def test_invitation_foreign_join_and_call_events_blocked(self):
        self.assertEqual(await self.policy.user_may_invite(self.owner, '@friend:local', '!private:local'), 'forbidden')
        for kind in ('m.call.invite', 'm.call.member', 'org.matrix.msc3401.call.member'):
            self.assertFalse(await self.allowed(self.event(kind)))
        for sender, target in ((self.owner, '@friend:local'), ('@friend:local', '@friend:local'), ('@friend:local', self.owner)):
            self.assertFalse(await self.allowed(self.event('m.room.member', sender, target, {'membership': 'join'})))
        self.assertTrue(await self.allowed(self.event('m.room.member', key=self.owner, content={'membership': 'join'})))
        self.assertTrue(await self.allowed(self.event('m.room.encrypted', content={'ciphertext': 'encrypted'})))
    async def test_creation_marker_cannot_be_redacted_and_ordinary_rooms_unchanged(self):
        for event in (self.event('m.room.redaction', redacts='$create'), self.event('m.room.redaction', content={'redacts': '$create'})):
            self.assertFalse(await self.allowed(event))
        self.assertTrue(await self.allowed(self.event('m.room.redaction', redacts='$message')))
        self.creation.content = {}
        self.assertTrue(await self.allowed(self.event('m.call.invite')))
        self.assertTrue(await self.allowed(self.event('m.room.member', '@friend:local', '@friend:local')))

if __name__ == '__main__': unittest.main()
