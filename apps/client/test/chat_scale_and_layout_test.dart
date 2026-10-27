import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/chat_scale.dart';
import 'package:voicechat_probe/resizable_chat_layout.dart';

void main() {
  test(
    'Independent bounded scale persists and ignores corrupt numbers',
    () async {
      SharedPreferences.setMockInitialValues({});
      final scale = ChatScale();
      await scale.change(messages: 60);
      await scale.change(contacts: 120);
      final restored = ChatScale()..load(await SharedPreferences.getInstance());
      expect(restored.messages, 60);
      expect(restored.contacts, 120);
      expect(ChatScale.valid(double.nan), 80);
      expect(ChatScale.valid(double.infinity), 80);
      expect(ChatScale.valid(-1), 60);
      expect(ChatScale.valid(999), 120);
      await scale.change(messages: 80, contacts: 80);
      restored.load(await SharedPreferences.getInstance());
      expect(restored.messages, 80);
      expect(restored.contacts, 80);
    },
  );
  testWidgets('Scale lays out wrapping content and transforms button hit tests', (
    tester,
  ) async {
    for (final percent in [60.0, 80.0, 120.0]) {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                child: ChatScaled(
                  percent: percent,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Длинное сообщение с переносами строк, изображением и действиями, которые остаются в пределах ширины.',
                      ),
                      SizedBox(
                        key: const ValueKey('circle'),
                        width: 160,
                        height: 160,
                        child: const ColoredBox(color: Colors.blue),
                      ),
                      IconButton(
                        tooltip: 'Скопировать',
                        onPressed: () => taps++,
                        icon: const Icon(Icons.copy),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final circle = tester.getRect(find.byKey(const ValueKey('circle')));
      expect(circle.width, closeTo(160 * percent / 80, .01));
      await tester.tap(find.byTooltip('Скопировать'));
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets(
    'Sidebar clamps drag, changes narrow navigation and restores width',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Widget app() => MaterialApp(
        home: Scaffold(
          body: ResizableChatLayout(
            sidebar: (compact) => ColoredBox(
              key: const ValueKey('sidebar'),
              color: Colors.blue,
              child: Text(compact ? 'Аватары' : 'Полный список'),
            ),
            conversation: const Text('Чат'),
          ),
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final boundary = find.bySemanticsLabel('Ширина списка людей и групп');
      expect(tester.getSize(find.byKey(const ValueKey('sidebar'))).width, 300);
      await tester.drag(boundary, const Offset(1000, 0));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('sidebar'))).width,
        closeTo(1000 / 3, .1),
      );
      await tester.drag(boundary, const Offset(-1000, 0));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const ValueKey('sidebar'))).width, 70);
      expect(find.text('Аватары'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const ValueKey('sidebar'))).width, 70);
      expect(tester.takeException(), isNull);
    },
  );
}
