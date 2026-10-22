import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/call_probe.dart';
import 'chat_actions_test.dart' show OutboxDatabase, OutboxRoom;

class CleanupClient extends Client {
  CleanupClient() : super('cleanup', database: OutboxDatabase());
  @override
  String get userID => '@self:local';
  @override
  String get deviceID => 'D';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Failed key setup disposes the per-call provider exactly once before close completes',
    () async {
      final methods = <String>[];
      const channel = MethodChannel('FlutterWebRTC.Method');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (method) async {
        methods.add(method.method);
        if (method.method == 'frameCryptorFactoryCreateKeyProvider') {
          return {'keyProviderId': 'test-provider'};
        }
        if (method.method == 'keyProviderSetKey') {
          throw PlatformException(code: 'test-failure');
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final call = CallProbe(
        chat: OutboxRoom(CleanupClient()),
        session: 'test',
        tokenUrl: 'http://localhost:8090',
        livekitUrl: 'ws://localhost:7880',
        status: (_) {},
      );
      await expectLater(call.connect(), throwsA(anything));
      expect(call.isClosed, true);
      expect(methods.where((m) => m == 'keyProviderDispose').length, 1);
      await Future.wait([call.close(), call.close()]);
      expect(methods.where((m) => m == 'keyProviderDispose').length, 1);
    },
  );
}
