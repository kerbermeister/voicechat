import json
import socket
import time
import unittest
from email.message import Message
from unittest.mock import patch, Mock
from link_preview import Metadata, preview, public_target, fetch, youtube_video_id


def address(ip):
    return (socket.AF_INET, socket.SOCK_STREAM, 6, '', (ip, 443))


class PreviewTests(unittest.TestCase):
    def test_connection_is_pinned_and_redirect_is_checked_again(self):
        response = Mock(status=302)
        response.getheader.return_value = 'http://127.0.0.1/private'
        connection = Mock()
        connection.getresponse.return_value = response
        with patch('socket.getaddrinfo', side_effect=[[address('1.1.1.1')], [address('127.0.0.1')]]), \
             patch('socket.create_connection') as connect, \
             patch('http.client.HTTPConnection', return_value=connection):
            with self.assertRaises(ValueError): fetch('http://example.com/start', 1024, time.monotonic() + 10)
            self.assertEqual(connect.call_args.args[0], ('1.1.1.1', 80))
            connection.close.assert_called_once()

    def test_public_address_and_mixed_dns(self):
        for ip in ('127.0.0.1', '10.0.0.1', '169.254.169.254', '::1', 'fc00::1', '::ffff:127.0.0.1', '224.0.0.1', 'ff02::1'):
            with patch('socket.getaddrinfo', return_value=[address(ip)]):
                with self.assertRaises(ValueError): public_target('https://example.com')
        with patch('socket.getaddrinfo', return_value=[address('1.1.1.1'), address('127.0.0.1')]):
            with self.assertRaises(ValueError): public_target('https://example.com')
        with patch('socket.getaddrinfo', return_value=[address('1.1.1.1')]):
            self.assertEqual(public_target('https://example.com/path')[3], '1.1.1.1')
        for url in ('file:///etc/passwd', 'https://user:secret@example.com', 'https://example.com:8008/', 'https://example.com/\r\nHost:evil'):
            with self.assertRaises(ValueError): public_target(url)

    def test_metadata_is_text_and_image_failure_keeps_card(self):
        headers = Message()
        headers['Content-Type'] = 'text/html; charset=utf-8'
        body = b'<title>Fallback</title><meta property="og:title" content="A &amp; B"><meta name="description" content="Text"><meta property="og:image" content="http://127.0.0.1/private"><script>alert(1)</script>'
        with patch('link_preview.fetch', side_effect=[('https://example.com/', headers, body), ValueError('private_address')]):
            result = preview('https://example.com/')
        self.assertEqual(result, {'url': 'https://example.com/', 'title': 'A & B', 'description': 'Text'})
        parser = Metadata()
        parser.feed('<title>' + 'x' * 10000 + '</title>')
        self.assertLessEqual(len(parser.title), 512)

    def test_youtube_uses_bounded_oembed_preserving_original_url(self):
        url = 'https://www.youtube.com/watch?v=D6Gs_yf71bo&list=RDD6Gs_yf71bo&start_radio=1'
        headers = Message()
        headers['Content-Type'] = 'application/json'
        metadata = json.dumps({'title': 'Song', 'author_name': 'Artist',
                               'html': '<script>never forward</script>',
                               'thumbnail_url': 'http://127.0.0.1/private'}).encode()
        with patch('socket.getaddrinfo', return_value=[address('1.1.1.1')]), \
             patch('link_preview.fetch', side_effect=[('https://www.youtube.com/oembed', headers, metadata), ValueError('private_address')]) as load:
            result = preview(url)
        self.assertEqual(result, {'url': url, 'title': 'Song', 'description': 'YouTube · Artist'})
        self.assertTrue(load.call_args_list[0].args[0].startswith('https://www.youtube.com/oembed?url='))
        self.assertNotIn('list=', load.call_args_list[0].args[0])
        self.assertEqual(load.call_args_list[0].args[1], 16 * 1024)

    def test_youtube_does_not_bypass_original_address_validation(self):
        for url in ('https://user@www.youtube.com/watch?v=D6Gs_yf71bo',
                    'https://www.youtube.com:444/watch?v=D6Gs_yf71bo'):
            with patch('link_preview.fetch') as load:
                with self.assertRaises(ValueError): preview(url)
                load.assert_not_called()
        with patch('socket.getaddrinfo', return_value=[address('127.0.0.1')]), \
             patch('link_preview.fetch') as load:
            with self.assertRaises(ValueError): preview('https://youtu.be/D6Gs_yf71bo')
            load.assert_not_called()
        for value in (None, 1, 'x' * 2049):
            with self.assertRaises(ValueError): youtube_video_id(value)
        self.assertIsNone(youtube_video_id('https://www.youtube.com.attacker.test/watch?v=D6Gs_yf71bo'))
        self.assertEqual(youtube_video_id('https://youtu.be/D6Gs_yf71bo'), 'D6Gs_yf71bo')
        self.assertEqual(youtube_video_id('https://m.youtube.com/shorts/D6Gs_yf71bo'), 'D6Gs_yf71bo')

    def test_youtube_malformed_response_is_not_a_success(self):
        headers = Message()
        headers['Content-Type'] = 'application/json'
        for metadata in (b'null', b'[]', b'{}', b'{"title":1}', b'{"title":" "}', b'{'):
            with patch('socket.getaddrinfo', return_value=[address('1.1.1.1')]), \
                 patch('link_preview.fetch', return_value=('https://www.youtube.com/oembed', headers, metadata)):
                with self.assertRaises(ValueError): preview('https://youtu.be/D6Gs_yf71bo')


if __name__ == '__main__': unittest.main()
