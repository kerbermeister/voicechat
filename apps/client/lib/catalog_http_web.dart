import 'dart:async';
import 'dart:js_interop';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

http.Client catalogClient() => _CatalogClient();

/// Public discovery must omit even same-origin browser cookies and HTTP auth.
/// BrowserClient.withCredentials=false still sends same-origin credentials.
class _CatalogClient extends http.BaseClient {
  final _controllers = <web.AbortController>{};
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed || request.method != 'GET' || request.headers.isNotEmpty) {
      throw http.ClientException(
        'Catalog client requires an anonymous GET',
        request.url,
      );
    }
    final body = await request.finalize().toBytes();
    if (_closed || body.isNotEmpty) {
      throw http.ClientException(
        'Catalog GET must not carry a body',
        request.url,
      );
    }
    final controller = web.AbortController();
    _controllers.add(controller);
    if (request is http.Abortable && request.abortTrigger != null) {
      unawaited(
        request.abortTrigger!.then(
          (_) => controller.abort(),
          onError: (_) => controller.abort(),
        ),
      );
    }
    final response = await web.window
        .fetch(
          request.url.toString().toJS,
          web.RequestInit(
            method: 'GET',
            credentials: 'omit',
            redirect: 'error',
            cache: 'no-store',
            signal: controller.signal,
          ),
        )
        .toDart;
    final rawLength = response.headers.get('content-length');
    final length = rawLength == null ? null : int.tryParse(rawLength);
    if (rawLength != null && (length == null || length < 0)) {
      throw http.ClientException('Invalid catalog content length', request.url);
    }
    return http.StreamedResponse(
      _body(response),
      response.status,
      contentLength: length,
      headers: {'content-type': response.headers.get('content-type') ?? ''},
      request: request,
    );
  }

  Stream<List<int>> _body(web.Response response) async* {
    final reader =
        response.body?.getReader() as web.ReadableStreamDefaultReader?;
    if (reader == null) return;
    try {
      while (true) {
        final chunk = await reader.read().toDart;
        if (chunk.done) return;
        yield (chunk.value! as JSUint8Array).toDart;
      }
    } finally {
      try {
        await reader.cancel().toDart;
      } catch (_) {
        // An already aborted fetch may reject cancel; the original read error
        // still propagates and the caller closes its AbortController.
      }
      reader.releaseLock();
    }
  }

  @override
  void close() {
    _closed = true;
    for (final controller in _controllers) {
      controller.abort();
    }
    _controllers.clear();
  }
}
