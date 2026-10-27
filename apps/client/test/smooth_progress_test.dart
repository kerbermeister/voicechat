import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/smooth_progress_ring.dart';
import 'package:voicechat_probe/animated_message_border.dart';
import 'package:voicechat_probe/app_motion.dart';

void main() {
  testWidgets('Progress advances each display frame and freezes on pause', (
    tester,
  ) async {
    Widget app(double value, bool running, {bool reduce = false}) =>
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
            child: child!,
          ),
          home: Scaffold(
            body: SizedBox.square(
              dimension: 200,
              child: SmoothProgressRing(
                value: value,
                running: running,
                duration: const Duration(seconds: 10),
              ),
            ),
          ),
        );
    double progress() => tester
        .widget<CircularProgressIndicator>(
          find.byType(CircularProgressIndicator),
        )
        .value!;
    await tester.pumpWidget(app(.1, true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final first = progress();
    expect(first, greaterThan(.1));
    await tester.pump(const Duration(milliseconds: 16));
    expect(progress(), greaterThan(first));
    await tester.pumpWidget(app(progress(), false));
    final paused = progress();
    await tester.pump(const Duration(milliseconds: 500));
    expect(progress(), paused);
    await tester.pumpWidget(app(0, true));
    expect(progress(), lessThan(.01));
    await tester.pumpWidget(app(.4, true, reduce: true));
    await tester.pump(const Duration(milliseconds: 500));
    expect(progress(), closeTo(.4, .001));
    expect(tester.binding.hasScheduledFrame, false);
  });
  testWidgets(
    'Animated border paints without changing geometry and respects reduced motion',
    (tester) async {
      final childKey = GlobalKey();
      Widget app(bool reduce, {bool visible = true}) => MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: AnimatedPanel(
              child: visible
                  ? AnimatedMessageBorder(
                      key: childKey,
                      child: const SizedBox(width: 200, height: 80),
                    )
                  : null,
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(false));
      final before = tester.getRect(find.byKey(childKey));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getRect(find.byKey(childKey)), before);
      expect(tester.binding.hasScheduledFrame, true);
      await tester.pumpWidget(app(true));
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, false);
      await tester.pumpWidget(app(true, visible: false));
      await tester.pumpAndSettle();
      expect(find.byKey(childKey), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
