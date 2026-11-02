"""Execute the actual Synapse resource against its installed datastore contract."""
import ast
import hmac
import io
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock


class ServerError(Exception):
    def __init__(self, code, message):
        self.code = code


namespace = {'DirectServeJsonResource': object, 'SynapseError': ServerError,
             'UserID': SimpleNamespace(from_string=lambda value: value), 'json': json, 'hmac': hmac}
source = ast.parse(Path(__file__).with_name('voicechat_policy.py').read_text())
nodes = [node for node in source.body if isinstance(node, ast.ClassDef) and node.name == 'StreamPair']
exec(compile(ast.Module(body=nodes, type_ignores=[]), 'voicechat_policy.py', 'exec'), namespace)


class StreamPairTests(unittest.IsolatedAsyncioTestCase):
    async def test_symmetric_ignore_and_internal_authorization(self):
        store = SimpleNamespace(ignored_users=AsyncMock(return_value=set()))
        hs = SimpleNamespace(is_mine=lambda _: True, get_datastores=lambda: SimpleNamespace(main=store))
        resource = namespace['StreamPair'](SimpleNamespace(secret='fixture', api=SimpleNamespace(_hs=hs)))
        def request(auth='Bearer fixture', **body):
            return SimpleNamespace(getHeader=lambda _: auth, content=io.BytesIO(json.dumps(body).encode()))
        body = dict(owner='@alice:local', viewer='@bob:local')
        self.assertEqual(await resource._async_render_POST(request(**body)), (200, {'allowed': True}))
        for ignored in ({'@alice:local'}, {'@bob:local'}):
            store.ignored_users.return_value = ignored
            self.assertEqual(await resource._async_render_POST(request(**body)), (200, {'allowed': False}))
        with self.assertRaises(ServerError) as error:
            await resource._async_render_POST(request(auth='Bearer wrong', **body))
        self.assertEqual(error.exception.code, 403)
        with self.assertRaises(ServerError) as error:
            await resource._async_render_POST(request(owner='@alice:local', viewer=42))
        self.assertEqual(error.exception.code, 400)
