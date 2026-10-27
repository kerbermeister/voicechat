import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/message_motion.dart';
import 'package:voicechat_probe/delete_message_dialog.dart';
import 'package:voicechat_probe/people_picker.dart';
import 'halo_capture_test.dart' show CaptureClient;

void main() {
  testWidgets('New group footer stays compact on a narrow window', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => PeoplePicker.group(
                  client: CaptureClient(),
                  allowedUsers: const {},
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.widgetWithText(TextButton, 'Отмена')).height,
      lessThanOrEqualTo(36),
    );
    expect(
      tester.getSize(find.widgetWithText(FilledButton, 'Создать')).height,
      lessThanOrEqualTo(36),
    );
    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect(dialog.actionsPadding, const EdgeInsets.fromLTRB(16, 4, 16, 8));
    expect(tester.takeException(), isNull);
  });
  for (final width in [320.0, 390.0, 900.0]) {
    for (final scale in [1.0, 1.7]) {
      testWidgets('Delete dialog fits $width at text scale $scale', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const Scaffold(body: DeleteMessageDialog(allowAll: true)),
          ),
        );
        final buttons = find.byType(FilledButton);
        expect(buttons, findsNWidgets(3));
        final rows = {
          for (var i = 0; i < 3; i++) tester.getTopLeft(buttons.at(i)).dy,
        };
        expect(
          rows.length,
          lessThanOrEqualTo(2),
          reason:
              'dialog ${tester.getSize(find.byType(AlertDialog))}, buttons ${[for (var i = 0; i < 3; i++) tester.getRect(buttons.at(i))]}',
        );
        for (var i = 0; i < 3; i++) {
          final rect = tester.getRect(buttons.at(i));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('Message highlight keeps geometry and respects reduced motion', (
    tester,
  ) async {
    var selected = false;
    var reduce = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
              child: Center(
                child: MessageMenuHighlight(
                  selected: selected,
                  child: const SizedBox(width: 180, height: 80),
                ),
              ),
            );
          },
        ),
      ),
    );
    final size = tester.getSize(find.byType(MessageMenuHighlight));
    update(() => selected = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.hasRunningAnimations, isTrue);
    expect(tester.getSize(find.byType(MessageMenuHighlight)), size);
    await tester.pumpAndSettle();
    update(() {
      reduce = true;
      selected = false;
    });
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TweenAnimationBuilder<double>>(
            find.descendant(
              of: find.byType(MessageMenuHighlight),
              matching: find.byType(TweenAnimationBuilder<double>),
            ),
          )
          .duration,
      Duration.zero,
    );
    expect(tester.getSize(find.byType(MessageMenuHighlight)), size);
  });
}
