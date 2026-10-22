import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/call_probe.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'chat_actions_test.dart' show OutboxDatabase, OutboxRoom;

class CleanupClient extends Client {
  CleanupClient() : super('cleanup', database: OutboxDatabase());
  @override
  String get userID => '@self:local';
  @override
  String get deviceID => 'D';
}

class BrokenMedia implements lk.Room {
  bool disposed = false;
  bool disconnectCalled = false;
  @override
  final lk.ConnectionState connectionState;
  BrokenMedia([this.connectionState = lk.ConnectionState.connected]);
  @override
  Future<void> disconnect() async {
    disconnectCalled = true;
    throw StateError('cleanup failure');
  }

  @override
  Future<bool> dispose() async {
    disposed = true;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
          throw PlatformException(
            code: 'test-failure',
            message: 'original key setup failure',
          );
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
      final broken = BrokenMedia();
      final retry = CallProbe(
        chat: OutboxRoom(CleanupClient()),
        session: 'retry',
        tokenUrl: 'http://localhost:8090',
        livekitUrl: 'ws://localhost:7880',
        status: (_) {},
      )..media = broken;
      await expectLater(
        retry.connect(),
        throwsA(
          predicate(
            (error) => error.toString().contains('original key setup failure'),
          ),
        ),
      );
      expect(broken.disposed, true);
      expect(retry.isClosed, true);
      await expectLater(retry.close(), throwsStateError);
      expect(methods.where((m) => m == 'keyProviderDispose').length, 2);
      final idle = BrokenMedia(lk.ConnectionState.disconnected);
      final unused = CallProbe(
        chat: OutboxRoom(CleanupClient()),
        session: 'idle',
        tokenUrl: 'http://localhost:8090',
        livekitUrl: 'ws://localhost:7880',
        status: (_) {},
      )..media = idle;
      await unused.close();
      expect(idle.disconnectCalled, false);
      expect(idle.disposed, true);
    },
  );
}
