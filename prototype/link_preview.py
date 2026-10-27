"""Opt-in previews. Connect only to a validated public IP, including redirects."""
import json
import re
import base64
import http.client
import ipaddress
import socket
import ssl
import time
from html.parser import HTMLParser
from urllib.parse import parse_qs, urlencode, urljoin, urlsplit, urlunsplit


def public_target(url):
    if not isinstance(url, str) or len(url) > 2048 or any(ord(c) < 33 for c in url):
        raise ValueError('invalid_url')
    parsed = urlsplit(url)
    if parsed.scheme not in ('https', 'http') or not parsed.hostname or parsed.username is not None or parsed.password is not None:
        raise ValueError('invalid_url')
    host = parsed.hostname.encode('idna').decode('ascii')
    port = parsed.port or (443 if parsed.scheme == 'https' else 80)
    if port != (443 if parsed.scheme == 'https' else 80):
        raise ValueError('invalid_port')
    addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    if not addresses or any(not ipaddress.ip_address(a[4][0]).is_global or ipaddress.ip_address(a[4][0]).is_multicast for a in addresses):
        raise ValueError('private_address')
    return parsed, host, port, addresses[0][4][0]


def fetch(url, limit, deadline):
    for _ in range(4):
        parsed, host, port, address = public_target(url)
        timeout = min(4, deadline - time.monotonic())
        if timeout <= 0:
            raise TimeoutError('preview_timeout')
        connection = http.client.HTTPConnection(host, port, timeout=timeout)
        try:
            connection.sock = socket.create_connection((address, port), timeout=timeout)
            if parsed.scheme == 'https':
                connection.sock = ssl.create_default_context().wrap_socket(connection.sock, server_hostname=host)
            path = urlunsplit(('', '', parsed.path or '/', parsed.query, ''))
            connection.request('GET', path, headers={
                'User-Agent': 'VoiceChat-LinkPreview/1.0', 'Accept-Encoding': 'identity',
            })
            response = connection.getresponse()
            if response.status in (301, 302, 303, 307, 308):
                next_url = urljoin(url, response.getheader('Location', ''))
                if parsed.scheme == 'https' and urlsplit(next_url).scheme != 'https':
                    raise ValueError('insecure_redirect')
                url = next_url
                continue
            if response.status != 200 or response.getheader('Content-Encoding', 'identity') != 'identity':
                raise ValueError('preview_unavailable')
            body = bytearray()
            while True:
                if time.monotonic() >= deadline:
                    raise TimeoutError('preview_timeout')
                block = response.read1(min(8192, limit + 1 - len(body)))
                if not block:
                    break
                body.extend(block)
                if len(body) > limit:
                    raise ValueError('response_too_large')
            return url, response.headers, bytes(body)
        finally:
            connection.close()
    raise ValueError('too_many_redirects')


class Metadata(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.values = {}
        self.in_title = False
        self.title = ''

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'title':
            self.in_title = True
        if tag == 'meta':
            key = (attrs.get('property') or attrs.get('name') or '').lower()
            if key in ('og:title', 'og:description', 'og:image', 'description'):
                self.values.setdefault(key, (attrs.get('content') or '')[:2048])

    def handle_endtag(self, tag):
        if tag == 'title':
            self.in_title = False

    def handle_data(self, data):
        if self.in_title and len(self.title) < 512:
            self.title += data[:512]


def youtube_video_id(url):
    if not isinstance(url, str) or len(url) > 2048:
        raise ValueError('invalid_url')
    parsed = urlsplit(url)
    parts = parsed.path.strip('/').split('/')
    host = (parsed.hostname or '').lower()
    video = None
    if host == 'youtu.be' and len(parts) == 1:
        video = parts[0]
    elif host in ('youtube.com', 'www.youtube.com', 'm.youtube.com', 'www.youtube-nocookie.com'):
        if parsed.path == '/watch':
            video = parse_qs(parsed.query).get('v', [None])[0]
        elif len(parts) == 2 and parts[0] in ('embed', 'shorts'):
            video = parts[1]
    return video if isinstance(video, str) and re.fullmatch(r'[A-Za-z0-9_-]{11}', video) else None


def add_cover(result, image, base, deadline):
    if not isinstance(image, str) or len(image) > 2048:
        return
    try:
        _, headers, body = fetch(urljoin(base, image), 192 * 1024, deadline)
        if headers.get_content_type() in ('image/jpeg', 'image/png', 'image/webp'):
            result['image'] = base64.b64encode(body).decode('ascii')
    except (OSError, ValueError, http.client.HTTPException):
        pass


def youtube_preview(url, video, deadline):
    public_target(url)  # Preserve original URL/port checks before using a fixed provider endpoint.
    endpoint = 'https://www.youtube.com/oembed?' + urlencode({
        'url': 'https://www.youtube.com/watch?v=' + video, 'format': 'json',
    })
    _, headers, body = fetch(endpoint, 16 * 1024, deadline)
    if headers.get_content_type() != 'application/json':
        raise ValueError('invalid_oembed')
    metadata = json.loads(body)
    if not isinstance(metadata, dict) or not isinstance(metadata.get('title'), str) or not metadata['title'].strip():
        raise ValueError('invalid_oembed')
    author = metadata.get('author_name')
    result = {'url': url, 'title': metadata['title'].strip()[:256],
              'description': ('YouTube · ' + author if isinstance(author, str) else 'YouTube')[:512]}
    # Never embed or forward provider-supplied HTML.
    add_cover(result, metadata.get('thumbnail_url'), endpoint, deadline)
    return result


def preview(url):
    deadline = time.monotonic() + 10
    video = youtube_video_id(url)
    if video:
        return youtube_preview(url, video, deadline)
    final, headers, body = fetch(url, 256 * 1024, deadline)
    if headers.get_content_type() not in ('text/html', 'application/xhtml+xml'):
        return {'url': url, 'title': urlsplit(final).hostname, 'description': ''}
    parser = Metadata()
    charset = headers.get_content_charset() or 'utf-8'
    if charset.lower() not in ('utf-8', 'windows-1251', 'windows-1252', 'iso-8859-1'):
        charset = 'utf-8'
    parser.feed(body.decode(charset, errors='replace'))
    result = {
        'url': url,
        'title': (parser.values.get('og:title') or parser.title).strip()[:256],
        'description': (parser.values.get('og:description') or parser.values.get('description') or '').strip()[:512],
    }
    add_cover(result, parser.values.get('og:image'), final, deadline)
    return result
