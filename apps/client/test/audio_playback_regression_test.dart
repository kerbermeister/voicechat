import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/chat_pane.dart';
import 'package:voicechat_probe/waveform_view.dart';
import '../integration_test/audio_playback_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <(String, String)>[];
  final positions = <String, int>{};
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<void> event(String id, String name, [dynamic value]) async {
    // Test the real AudioPlayer state machine against platform events.
    // ignore: deprecated_member_use
    await messenger.handlePlatformMessage(
      'xyz.luan/audioplayers/events/$id',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': name,
        'value': value,
      }),
      (_) {},
    );
  }

  setUp(() {
    calls.clear();
    positions.clear();
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        final id = (call.arguments as Map)['playerId'] as String;
        calls.add((id, call.method));
        if (call.method == 'create') {
          messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null,
          );
        }
        if (call.method == 'setSourceBytes' || call.method == 'setSourceUrl') {
          await event(id, 'audio.onPrepared', true);
        }
        if (call.method == 'getCurrentPosition') return positions[id] ?? 0;
        if (call.method == 'getDuration') return 1500;
        if (call.method == 'seek') {
          positions[id] = (call.arguments as Map)['position'] as int;
          await event(id, 'audio.onSeekComplete');
        }
        return null;
      },
    );
  });
  testWidgets(
    'Completion then switching/replay reloads released source, and seek and disposal keep playback usable',
    (tester) async {
      final room = mx.Room(id: '!fixture:local', client: AudioFixtureClient());
      final first = AudioFixtureEvent(room, 'first'),
          second = AudioFixtureEvent(room, 'second');
      Future<void> render({bool firstVisible = true}) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                if (firstVisible)
                  AttachmentView(key: const ValueKey('first'), event: first),
                AttachmentView(key: const ValueKey('second'), event: second),
              ],
            ),
          ),
        ),
      );
      Finder button(String id) => find.descendant(
        of: find.byKey(ValueKey(id)),
        matching: find.byType(IconButton),
      );
      await render();
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.tap(button('first'));
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      final id = calls.firstWhere((c) => c.$2 == 'resume').$1;
      await event(id, 'audio.onComplete');
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
        tester
            .widget<WaveformView>(
              find.descendant(
                of: find.byKey(const ValueKey('first')),
                matching: find.byType(WaveformView),
              ),
            )
            .progress,
        1,
      );
      await tester.tap(button('second'));
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.tap(button('first'));
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
        calls.where((c) => c.$1 == id && c.$2 == 'setSourceBytes').length,
        2,
        reason: 'Completed audio released its source and must be loaded again',
      );
      expect(find.byIcon(Icons.pause), findsOneWidget);
      final wave = find.descendant(
        of: find.byKey(const ValueKey('first')),
        matching: find.byType(WaveformView),
      );
      await tester.tapAt(tester.getCenter(wave));
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(positions[id], closeTo(750, 20));
      expect(find.byIcon(Icons.pause), findsOneWidget);
      await render(firstVisible: false);
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.tap(button('second'));
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byIcon(Icons.pause), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(tester.takeException(), isNull);
      calls.clear();
      positions.clear();
      final retryRoom = mx.Room(
        id: '!fixture:local',
        client: AudioFixtureClient(),
      );
      final voice = AudioFixtureEvent(retryRoom, 'retry')..failDownload = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AttachmentView(event: voice)),
        ),
      );
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.tap(find.byTooltip('Прослушать'));
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(voice.loads, 1);
      voice.failDownload = false;
      await tester.tap(find.byTooltip('Прослушать'));
      await tester.tap(
        find.byTooltip('Прослушать'),
      ); // Same-frame repeat must not queue another start.
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(voice.loads, 2);
      expect(
        calls.where((c) => c.$2 == 'setSourceBytes').length,
        1,
        reason: calls.toString(),
      );
      if (find.byIcon(Icons.pause).evaluate().isEmpty) {
        await tester.tap(find.byTooltip('Прослушать'));
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
      }
      expect(find.byIcon(Icons.pause), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(tester.takeException(), isNull);
    },
  );
}
