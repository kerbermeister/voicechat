import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/app_motion.dart';
import 'package:voicechat_probe/scheduled_view.dart';
import 'package:voicechat_probe/theme.dart';
import 'scheduled_queue_test.dart' show QueueService;

Widget app(Widget child) => MaterialApp(
  theme: AppPalette.halo.theme,
  locale: const Locale('ru'),
  supportedLocales: const [Locale('ru')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
    child: child!,
  ),
  home: Scaffold(body: child),
);

void main() {
  testWidgets(
    'Scheduled title and empty state are centered at phone and desktop sizes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final size in [
        const Size(320, 568),
        const Size(390, 844),
        const Size(1366, 768),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          app(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showAppDialog<void>(
                  context: context,
                  builder: (_) =>
                      ScheduledView(service: QueueService(), roomId: '!room'),
                ),
                child: const Text('Открыть'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Открыть'));
        await tester.pumpAndSettle();
        final empty = find.text(
          'В этом чате пока нет запланированных сообщений.',
        );
        final content = find
            .ancestor(of: empty, matching: find.byType(SizedBox))
            .first;
        final actual = tester.getCenter(empty),
            expected = tester.getCenter(content);
        expect(actual.dx, closeTo(expected.dx, .5));
        expect(actual.dy, closeTo(expected.dy, .5));
        final title = tester.getCenter(find.text('Запланированные сообщения'));
        expect(
          title.dx,
          closeTo(tester.getCenter(find.byType(AlertDialog)).dx, .5),
        );
        await tester.tap(find.text('Закрыть'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
  testWidgets(
    'Schedule retains the chosen date and time through picker cancellation and confirmation',
    (tester) async {
      DateTime? result;
      final initial = DateTime.now().add(const Duration(hours: 1));
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await chooseScheduledTime(
                  context,
                  172800,
                  initial: initial,
                );
              },
              child: const Text('Планировать'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Планировать'));
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(find.text('Отложенное сообщение')).dx,
        closeTo(tester.getCenter(find.byType(AlertDialog)).dx, .5),
      );
      await tester.tap(find.text('Дата'));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('Назад').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Время'));
      await tester.pumpAndSettle();
      expect(find.byType(TimePickerDialog), findsOneWidget);
      await tester.tap(find.text('Назад').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Применить'));
      await tester.pumpAndSettle();
      expect(result, initial);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Schedule errors stay in the dialog and do not accept a past time',
    (tester) async {
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => chooseScheduledTime(context, 0),
              child: const Text('Планировать'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Планировать'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Применить'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Выберите будущее время'), findsOneWidget);
      expect(find.text('Отложенное сообщение'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
