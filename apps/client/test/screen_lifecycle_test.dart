import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/call_probe.dart';
import 'package:voicechat_probe/screen_api.dart';
import 'package:voicechat_probe/screen_controller.dart';

class LifecycleDatabase extends Fake implements DatabaseApi {
  @override
  Future<void> close() async {}
}

class LifecycleRoom extends Fake implements lk.Room {
  @override
  lk.ConnectionState get connectionState => lk.ConnectionState.connected;
}

class LifecycleCall extends Fake implements CallProbe {
  @override
  final Room chat;
  LifecycleCall(this.chat);
  @override
  bool get isClosed => false;
  @override
  String get session => 'lifecycle';
  @override
  String get screenBindingLease => 'a' * 64;
  @override
  lk.Room get media => LifecycleRoom();
}

void main() {
  test(
    'close во время bind освобождает поздний lease; повтор close идемпотентен',
    () async {
      final client = Client('lifecycle', database: LifecycleDatabase());
      final call = LifecycleCall(Room(id: '!lifecycle:local', client: client));
      final waiting = Completer<void>(), called = Completer<void>();
      var releases = 0;
      final api = ScreenApi(
        'http://localhost',
        () => '',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/bind')) {
            called.complete();
            await waiting.future;
            return http.Response(
              jsonEncode({
                'binding_id': '22222222-2222-4222-8222-222222222222',
                'lease_id': 'b' * 64,
              }),
              200,
            );
          }
          expect(request.url.path, '/screen/unbind');
          releases++;
          return http.Response('{}', 200);
        }),
      );
      final controller = ScreenShareController(
        call,
        api,
        'ws://localhost:7880',
      );
      final connected = controller.connect();
      await called.future;
      await controller.close();
      waiting.complete();
      await connected;
      await controller.close();
      expect(releases, 1);
      expect(controller.isClosed, isTrue);
      controller.dispose();
      await client.dispose();
    },
  );
}
