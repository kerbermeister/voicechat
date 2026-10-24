import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/app_motion.dart';
import 'package:voicechat_probe/theme.dart';

void main() {
  testWidgets(
    'Panel fades and changes height quickly; outgoing actions are disabled',
    (tester) async {
      final visible = ValueNotifier(false);
      addTearDown(visible.dispose);
      var actions = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: visible,
              builder: (_, value, _) => Column(
                children: [
                  AnimatedPanel(
                    child: value
                        ? SizedBox(
                            height: 100,
                            child: TextButton(
                              onPressed: () => actions++,
                              child: const Text('Действие'),
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(key: ValueKey('below'), height: 20),
                ],
              ),
            ),
          ),
        ),
      );
      final initial = tester.getTopLeft(find.byKey(const ValueKey('below'))).dy;
      visible.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      final middle = tester.getTopLeft(find.byKey(const ValueKey('below'))).dy;
      expect(middle, greaterThan(initial));
      expect(middle, lessThan(initial + 100));
      final fade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.text('Действие'),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      expect(fade.opacity.value, inExclusiveRange(0, 1));
      await tester.pump(appMotionDuration);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('below'))).dy,
        initial + 100,
      );
      visible.value = false;
      await tester.pump();
      final guard = tester.widget<IgnorePointer>(
        find
            .ancestor(
              of: find.text('Действие'),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(guard.ignoring, true);
      final frames = await tester.pumpAndSettle(
        const Duration(milliseconds: 20),
      );
      expect(frames, lessThanOrEqualTo(11));
      expect(find.text('Действие'), findsNothing);
      expect(actions, 0);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('below'))).dy,
        initial,
      );
    },
  );

  testWidgets('Reduced motion skips panel effects and dialog transitions', (
    tester,
  ) async {
    final visible = ValueNotifier(false);
    addTearDown(visible.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppPalette.lavender.theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                ValueListenableBuilder(
                  valueListenable: visible,
                  builder: (_, value, _) => AnimatedPanel(
                    child: value
                        ? const SizedBox(height: 100, child: Text('Панель'))
                        : null,
                  ),
                ),
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    animationStyle: appAnimationStyle(context),
                    builder: (context) => AlertDialog(
                      title: Text(
                        '${ModalRoute.of(context)!.transitionDuration.inMilliseconds}',
                      ),
                    ),
                  ),
                  child: const Text('Окно'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    visible.value = true;
    await tester.pump();
    await tester.pump();
    expect(find.text('Панель'), findsOneWidget);
    visible.value = false;
    await tester.pump();
    await tester.pump();
    expect(find.text('Панель'), findsNothing);
    await tester.tap(find.text('Окно'));
    await tester.pumpAndSettle();
    expect(find.text('0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
