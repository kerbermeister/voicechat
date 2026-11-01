"""Execute the actual Synapse resource with an async datastore double."""
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


source = ast.parse(Path(__file__).with_name('voicechat_policy.py').read_text())
namespace = {'DirectServeJsonResource': object, 'SynapseError': ServerError, 'StoreError': ServerError,
             'UserID': SimpleNamespace(from_string=lambda value: value), 'json': json, 'hmac': hmac}
nodes = [node for node in source.body if isinstance(node, ast.ClassDef) and node.name == 'PushDevice']
exec(compile(ast.Module(body=nodes, type_ignores=[]), 'voicechat_policy.py', 'exec'), namespace)


class PushDeviceTests(unittest.IsolatedAsyncioTestCase):
    async def test_authorization_revocation_and_room_membership(self):
        store = SimpleNamespace(get_device=AsyncMock())
        api = SimpleNamespace(get_room_state=AsyncMock(return_value={
            ('m.room.member', '@bob:local'): SimpleNamespace(content={'membership': 'join'})}))
        api._hs = SimpleNamespace(is_mine=lambda _: True, get_datastores=lambda: SimpleNamespace(main=store))
        resource = namespace['PushDevice'](SimpleNamespace(secret='test-secret', api=api))
        def request(auth='Bearer test-secret', room='!room:local'):
            return SimpleNamespace(getHeader=lambda _: auth,
                content=io.BytesIO(json.dumps({'user': '@bob:local', 'device': 'B', 'room': room}).encode()))
        with self.assertRaises(ServerError) as error:
            await resource._async_render_POST(request('Bearer other'))
        self.assertEqual(error.exception.code, 403)
        store.get_device.assert_not_called()
        self.assertEqual(await resource._async_render_POST(request()), (200, {'valid': True}))
        api.get_room_state.return_value = {}
        self.assertEqual(await resource._async_render_POST(request()), (200, {'valid': False}))
        self.assertEqual(await resource._async_render_POST(request(room='')), (200, {'valid': True}))
        store.get_device.side_effect = ServerError(404, 'revoked')
        self.assertEqual(await resource._async_render_POST(request()), (200, {'valid': False}))
