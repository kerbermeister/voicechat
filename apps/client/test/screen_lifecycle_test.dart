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
import 'package:voicechat_probe/screen_capture.dart';
import 'screen_capture_test.dart' show CaptureTrack;

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

class DeadlineVideo extends Fake implements lk.LocalVideoTrack {
  final track = CaptureTrack();
  @override
  CaptureTrack get mediaStreamTrack => track;
}

class DeadlineCapture extends ScreenCapture {
  int closes = 0;
  DeadlineCapture(super.source);
  @override
  Future<void> close() async {
    closes++;
    await source.mediaStreamTrack.stop();
  }
}

void main() {
  test(
    'После picker claim использует свежий roster; отказ проверки закрывает capture',
    () async {
      for (final denied in [false, true]) {
        final client = Client('fresh-claim', database: LifecycleDatabase());
        final call = LifecycleCall(
          Room(id: '!lifecycle:local', client: client),
        );
        const binding = '22222222-2222-4222-8222-222222222222';
        final events = <String>[];
        Map<String, dynamic> snapshot(int revision) => {
          'protocol_version': 1,
          'binding_id': binding,
          'state': 'idle',
          'revision': revision,
          'roster_version': revision,
          'roster': [],
          'owner_identity': null,
          'generation': null,
        };
        final api = ScreenApi(
          'http://localhost',
          () => '',
          client: MockClient((request) async {
            if (request.url.path.endsWith('/bind')) {
              return http.Response(
                jsonEncode({
                  'binding_id': binding,
                  'lease_id': 'b' * 64,
                  'binding_state': 'open',
                  'snapshot': snapshot(0),
                }),
                200,
              );
            }
            if (request.url.path.endsWith('/heartbeat')) {
              events.add('heartbeat');
              return denied
                  ? http.Response('{"error":"screen_access_denied"}', 403)
                  : http.Response(jsonEncode({'snapshot': snapshot(4)}), 200);
            }
            if (request.url.path.endsWith('/claim')) {
              events.add(
                'claim:${jsonDecode(request.body)['expected_revision']}',
              );
              return http.Response('{"error":"screen_revision_conflict"}', 409);
            }
            return http.Response('{}', 200);
          }),
        );
        final capture = DeadlineCapture(DeadlineVideo());
        final controller = ScreenShareController(
          call,
          api,
          'ws://localhost:7880',
          captureFactory: () async {
            events.add('capture');
            return capture;
          },
        );
        await controller.connect();
        await controller.share();
        expect(
          events,
          denied
              ? ['capture', 'heartbeat']
              : ['capture', 'heartbeat', 'claim:4'],
        );
        expect(capture.closes, 1);
        await controller.close();
        controller.dispose();
        await client.dispose();
      }
    },
  );
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
  test(
    'Выключатель завершает клиентский контекст сразу, без ожидания lease',
    () async {
      final client = Client('disabled', database: LifecycleDatabase());
      final call = LifecycleCall(Room(id: '!lifecycle:local', client: client));
      var releases = 0;
      final api = ScreenApi(
        'http://localhost',
        () => '',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/bind')) {
            return http.Response(
              jsonEncode({
                'binding_id': '22222222-2222-4222-8222-222222222222',
                'lease_id': 'b' * 64,
                'binding_state': 'pending',
                'snapshot': {
                  'protocol_version': 1,
                  'binding_id': '22222222-2222-4222-8222-222222222222',
                  'state': 'idle',
                  'revision': 0,
                  'roster_version': 0,
                  'roster': [],
                  'owner_identity': null,
                  'generation': null,
                },
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/state')) {
            return http.Response('{"error":"screen_disabled"}', 503);
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
      await controller.connect();
      await controller.poll();
      expect(controller.isClosed, isTrue);
      expect(releases, 1);
      controller.dispose();
      await client.dispose();
    },
  );
  testWidgets(
    'Зависший claim освобождает подготовленный capture за 15 секунд',
    (tester) async {
      for (final pending in [false, true]) {
        final client = Client('timeout', database: LifecycleDatabase());
        final call = LifecycleCall(
          Room(id: '!lifecycle:local', client: client),
        );
        final response = Completer<http.Response>();
        final api = ScreenApi(
          'http://localhost',
          () => '',
          client: MockClient((request) async {
            if (request.url.path.endsWith('/bind')) {
              return http.Response(
                jsonEncode({
                  'binding_id': '22222222-2222-4222-8222-222222222222',
                  'lease_id': 'b' * 64,
                  'binding_state': 'open',
                  'snapshot': {
                    'protocol_version': 1,
                    'binding_id': '22222222-2222-4222-8222-222222222222',
                    'state': 'idle',
                    'revision': 0,
                    'roster_version': 0,
                    'roster': [],
                    'owner_identity': null,
                    'generation': null,
                  },
                }),
                200,
              );
            }
            if (request.url.path.endsWith('/heartbeat')) {
              return http.Response(
                jsonEncode({
                  'snapshot': {
                    'protocol_version': 1,
                    'binding_id': '22222222-2222-4222-8222-222222222222',
                    'state': 'idle',
                    'revision': 0,
                    'roster_version': 0,
                    'roster': [],
                    'owner_identity': null,
                    'generation': null,
                  },
                }),
                200,
              );
            }
            if (request.url.path.endsWith('/claim')) {
              if (pending) {
                return http.Response(
                  jsonEncode({
                    'status': 'pending',
                    'snapshot': {
                      'protocol_version': 1,
                      'binding_id': '22222222-2222-4222-8222-222222222222',
                      'revision': 1,
                      'roster_version': 0,
                      'state': 'switching',
                      'owner_identity': 'null/null',
                      'generation': 'screen-${'a' * 48}',
                      'roster': [],
                    },
                  }),
                  202,
                );
              }
              return response.future;
            }
            return http.Response('{}', 200);
          }),
        );
        final video = DeadlineVideo();
        final capture = DeadlineCapture(video);
        final controller = ScreenShareController(
          call,
          api,
          'ws://localhost:7880',
          captureFactory: () async => capture,
        );
        await tester.runAsync(controller.connect);
        final sharing = controller.share();
        await tester.pump();
        await tester.pump(const Duration(seconds: 16));
        for (var i = 0; i < 10 && controller.busy; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(capture.closes, 1);
        expect(controller.busy, isFalse);
        expect(controller.notice, contains('вовремя'));
        await sharing;
        expect(video.track.stops, greaterThan(0));
        expect(capture.closes, 1);
        if (!pending) {
          response.complete(
            http.Response('{"error":"screen_unavailable"}', 503),
          );
        }
        await tester.pump();
        await tester.runAsync(controller.close);
        controller.dispose();
        await client.dispose();
      }
    },
  );
}
