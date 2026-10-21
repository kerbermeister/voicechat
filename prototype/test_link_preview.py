import socket
import time
import unittest
from email.message import Message
from unittest.mock import patch, Mock
from link_preview import Metadata, preview, public_target, fetch


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


if __name__ == '__main__': unittest.main()
