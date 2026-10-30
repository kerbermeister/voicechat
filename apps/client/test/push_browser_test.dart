@TestOn('browser')
library;

import 'dart:js_interop';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voicechat_probe/push_notifications.dart';
import 'package:voicechat_probe/route_transport.dart';

@JS('globalThis.VoiceChatPush')
external set pushFixture(JSObject value);

class ClosingClient extends MockClient {
  bool closed = false;
  ClosingClient(super.handler);
  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  test(
    'Compiled JS bridge retains synchronous invocation and owns its routed pool',
    () async {
      var invoked = false;
      final requests = <Uri>[];
      final inner = ClosingClient((request) async {
        requests.add(request.url);
        return http.Response('{"binding":"synthetic"}', 200);
      });
      final client = RouteTransport(
        origin: Uri.parse('https://canonical.example'),
        routes: [Uri.parse('https://c.example')],
        inner: inner,
      );
      Future<JSString> exercise(JSFunction request) async {
        final response =
            await (request.callAsFunction(null, 'config'.toJS, null)
                    as JSPromise<JSString>)
                .toDart;
        expect(response.toDart, '{"binding":"synthetic"}');
        return 'ok'.toJS;
      }

      final invoke = ((JSString base, JSString token, JSFunction request) {
        invoked = true;
        expect(base.toDart, 'https://canonical.example/api');
        expect(token.toDart, 'fixture');
        return exercise(request).toJS;
      }).toJS;
      pushFixture = {'enable': invoke, 'disable': invoke}.jsify() as JSObject;
      final pending = enablePushNotifications(
        'https://canonical.example/api',
        'fixture',
        createClient: () => client,
      );
      expect(invoked, true);
      expect(await pending, 'ok');
      expect(requests.single.toString(), 'https://c.example/api/push/config');
      expect(inner.closed, true);
    },
  );
}
