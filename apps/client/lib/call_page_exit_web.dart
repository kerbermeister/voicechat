import 'dart:js_interop';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

bool _leaving = false;

void Function() listenCallPageExit(void Function() leave) {
  // pagehide also covers bfcache navigation. A hidden tab is not a closed tab:
  // switching tabs, opening a picker or locking a phone must not hang up.
  final handler = ((web.Event _) {
    _leaving = true;
    leave();
  }).toJS;
  final resume = ((web.Event _) {
    _leaving = false;
  }).toJS;
  web.window.addEventListener('pagehide', handler);
  web.document.addEventListener('freeze', handler);
  web.window.addEventListener('pageshow', resume);
  web.document.addEventListener('resume', resume);
  return () {
    web.window.removeEventListener('pagehide', handler);
    web.document.removeEventListener('freeze', handler);
    web.window.removeEventListener('pageshow', resume);
    web.document.removeEventListener('resume', resume);
    _leaving = false;
  };
}

/// Called only after RouteTransport validates and selects a trusted destination.
/// Keep the authenticated, encrypted writes alive across page teardown; no redirects.
Future<http.StreamedResponse>? sendCallPageExit(http.BaseRequest request) {
  final path = request.url.path;
  final terminal =
      request.method == 'POST' && path == '/api/call/leave' ||
      request.method == 'PUT' &&
          path.startsWith('/_matrix/client/') &&
          path.contains('/send/');
  if (!_leaving ||
      !terminal ||
      request.contentLength == null ||
      request.contentLength! > 65536) {
    return null;
  }
  return _send(request);
}

Future<http.StreamedResponse> _send(http.BaseRequest request) async {
  try {
    final bytes = await request.finalize().toBytes();
    if (bytes.length > 65536) {
      throw http.ClientException('Exit request too large');
    }
    final response = await web.window
        .fetch(
          request.url.toString().toJS,
          web.RequestInit(
            method: request.method,
            body: bytes.toJS,
            headers: request.headers.jsify()! as web.HeadersInit,
            credentials: 'omit',
            redirect: 'error',
            keepalive: true,
          ),
        )
        .toDart;
    final body = (await response.arrayBuffer().toDart).toDart.asUint8List();
    return http.StreamedResponse(
      Stream.value(body),
      response.status,
      request: request,
      reasonPhrase: response.statusText,
    );
  } catch (error) {
    throw http.ClientException(error.toString(), request.url);
  }
}
