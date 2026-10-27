import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/chat_pane.dart';
import 'package:voicechat_probe/waveform_view.dart';
import 'audio_playback_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Real macOS audio resumes after completion and switching, seeks and survives old widget disposal',
    (tester) async {
      final room = mx.Room(
        id: '!audio-fixture:local',
        client: AudioFixtureClient(),
      );
      final first = AudioFixtureEvent(room, 'first', milliseconds: 1000),
          second = AudioFixtureEvent(room, 'second', milliseconds: 3000);
      Future<void> render({bool showFirst = true}) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                if (showFirst)
                  AttachmentView(
                    key: const ValueKey('first'),
                    event: first,
                    volume: 0,
                  ),
                AttachmentView(
                  key: const ValueKey('second'),
                  event: second,
                  volume: 0,
                ),
              ],
            ),
          ),
        ),
      );
      Future<void> advance(int milliseconds) async {
        for (var time = 0; time < milliseconds; time += 50) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
          await tester.pump();
        }
      }

      Finder view(String id) => find.byKey(ValueKey(id));
      Finder button(String id) =>
          find.descendant(of: view(id), matching: find.byType(IconButton));
      WaveformView wave(String id) => tester.widget<WaveformView>(
        find.descendant(of: view(id), matching: find.byType(WaveformView)),
      );
      await render();
      await advance(150);
      await tester.tap(button('first'));
      await advance(1700);
      expect(
        find.byIcon(Icons.pause),
        findsNothing,
        reason: 'First silent fixture completed on AVPlayer',
      );
      await tester.tap(button('second'));
      await advance(300);
      expect(wave('second').progress, greaterThan(.02));
      await tester.tap(button('first'));
      await advance(300);
      expect(
        wave('first').progress,
        inExclusiveRange(.05, .95),
        reason: 'Previously completed audio must advance again',
      );
      expect(find.byIcon(Icons.pause), findsOneWidget);
      await tester.tap(button('second'));
      await advance(200);
      final seek = find.descendant(
        of: view('second'),
        matching: find.byType(WaveformView),
      );
      await tester.tapAt(tester.getCenter(seek));
      await advance(200);
      expect(wave('second').progress, inExclusiveRange(.45, .85));
      await render(showFirst: false);
      await advance(150);
      await tester.tap(button('second'));
      await advance(100); // pause
      await tester.tap(button('second'));
      await advance(200); // resume
      expect(find.byIcon(Icons.pause), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await advance(150);
      expect(tester.takeException(), isNull);
    },
  );
}
