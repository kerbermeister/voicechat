import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/chat_pane.dart';
import '../integration_test/audio_playback_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final name in [
    'xyz.luan/audioplayers.global',
    'xyz.luan/audioplayers.global/events',
  ]) {
    messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }
  messenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    (call) async {
      if (call.method == 'create') {
        final id = (call.arguments as Map)['playerId'];
        messenger.setMockMethodCallHandler(
          MethodChannel('xyz.luan/audioplayers/events/$id'),
          (_) async => null,
        );
      }
      return null;
    },
  );
  testWidgets(
    'Encrypted 48 kHz voice longer than the old 10 MB cap can be loaded',
    (tester) async {
      final room = mx.Room(
        id: '!high-quality:local',
        client: AudioFixtureClient(),
      );
      final voice = AudioFixtureEvent(
        room,
        'high-quality',
        milliseconds: 120000,
        sampleRate: 48000,
      );
      expect(voice.bytes.length, greaterThan(10 * 1024 * 1024));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AttachmentView(event: voice)),
        ),
      );
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(AttachmentView)) as dynamic;
      final file = await state.load() as mx.MatrixFile;
      expect(file.bytes, same(voice.bytes));
      expect(voice.loads, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
