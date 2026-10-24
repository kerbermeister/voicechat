import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/scheduled_messages.dart';
import 'package:voicechat_probe/scheduled_view.dart';
import 'package:voicechat_probe/theme.dart';
import 'message_test.dart' show TestClient;

class QueueService extends ScheduledMessages {
  final jobs = <Map<String, dynamic>>[];
  bool unavailable = false;
  QueueService() : super(TestClient(), 'http://localhost:8090');
  @override
  Future<List<Map<String, dynamic>>> list() async {
    if (unavailable) throw StateError('Offline');
    return jobs.map((job) => Map<String, dynamic>.from(job)).toList();
  }

  @override
  Future<String> preview(String id) async => 'Содержимое $id';
  @override
  Future<void> cancel(String id) async =>
      jobs.firstWhere((job) => job['id'] == id)['state'] = 'cancelled';
}

void main() {
  testWidgets(
    'Queue counts active jobs in this chat, opens content, and refreshes after cancellation',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = QueueService();
      final changes = ChangeNotifier();
      addTearDown(changes.dispose);
      for (final (id, room, state) in [
        ('one', '!chat', 'pending'),
        ('two', '!chat', 'retry'),
        ('other', '!other', 'pending'),
        ('old', '!chat', 'sent'),
        ('cancelled', '!chat', 'cancelled'),
      ]) {
        service.jobs.add({
          'id': id,
          'room_id': room,
          'state': state,
          'due': DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        });
      }
      for (final size in [const Size(320, 640), const Size(1440, 900)]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppPalette.lavender.theme,
            home: Scaffold(
              body: ScheduledQueueBar(
                key: UniqueKey(),
                service: service,
                roomId: '!chat',
                changes: changes,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Запланировано · 2'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('Запланировано · 2'));
      await tester.pumpAndSettle();
      expect(find.text('Содержимое one'), findsOneWidget);
      expect(find.text('Содержимое two'), findsOneWidget);
      expect(find.text('Содержимое other'), findsNothing);
      expect(find.text('Опубликовано'), findsNothing);
      await tester.tap(find.byTooltip('Отменить запланированное сообщение'));
      await tester.pumpAndSettle();
      expect(find.text('Содержимое one'), findsNothing);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      expect(find.text('Запланировано · 1'), findsOneWidget);
      service.unavailable = true;
      changes.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Запланировано · 1'), findsOneWidget);
      expect(find.textContaining('Нет обновления'), findsOneWidget);
      service.unavailable = false;
      service.jobs.firstWhere((job) => job['id'] == 'two')['state'] = 'sent';
      changes.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.textContaining('Запланировано'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
