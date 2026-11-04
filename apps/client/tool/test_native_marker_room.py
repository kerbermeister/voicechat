import base64
from io import BytesIO
import json
import unittest
from unittest.mock import patch

from call_sfu_marker_lab import create_marker_room


class MarkerRoomTest(unittest.TestCase):
    def test_native_room_keeps_fixed_bounds_and_explicit_grouping(self):
        with patch('urllib.request.urlopen', return_value=BytesIO(b'{"name":"route-probe"}')) as send:
            create_marker_room('127.0.0.1:17880', 'fixture', 'test-secret', False, 130, 130)
        request = send.call_args.args[0]
        self.assertEqual(json.loads(request.data), {
            'name': 'route-probe', 'max_participants': 10, 'sync_streams': False,
            'min_playout_delay': 130, 'max_playout_delay': 130,
        })
        claims = request.headers['Authorization'].split('.')[1]
        payload = json.loads(base64.urlsafe_b64decode(claims + '=' * (-len(claims) % 4)))
        self.assertEqual(payload['video'], {'roomCreate': True})
        self.assertLessEqual(payload['exp'] - payload['nbf'], 35)

    def test_control_omits_playout_extension(self):
        with patch('urllib.request.urlopen', return_value=BytesIO(b'{"name":"route-probe"}')) as send:
            create_marker_room('127.0.0.1:17880', 'fixture', 'test-secret')
        self.assertNotIn('min_playout_delay', json.loads(send.call_args.args[0].data))

    def test_bad_destination_or_delay_cannot_send_admin_token(self):
        with patch('urllib.request.urlopen') as send:
            for address in ('example.org:17880', '127.0.0.1:99999', '127.0.0.1:7880/path', 'localhost:7880'):
                with self.assertRaises(ValueError):
                    create_marker_room(address, 'fixture', 'test-secret')
            for low, high in ((True, 130), (130, 120), (-10, 130), (135, 130), (130, 10010)):
                with self.assertRaises(ValueError):
                    create_marker_room('127.0.0.1:17880', 'fixture', 'test-secret', False, low, high)
            send.assert_not_called()


if __name__ == '__main__':
    unittest.main()
