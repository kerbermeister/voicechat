import 'dart:async';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/send_failure.dart';
import 'package:voicechat_probe/chat_actions.dart';
import 'message_test.dart' show TestClient;
import 'package:voicechat_probe/user_action_error.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:markdown/markdown.dart' as md;
import 'package:voicechat_probe/message_format.dart';
import 'package:voicechat_probe/reaction_usage.dart';
import 'package:voicechat_probe/emoji_picker.dart';
import 'package:voicechat_probe/animated_emoji.dart';
import 'package:voicechat_probe/link_cards.dart';
import 'chat_actions_test.dart' show OutboxDatabase;

void main() {
  test(
    'Upload progress counts confirmed bytes rather than inventing a percentage',
    () {
      final actions = ChatActions(TestClient());
      final item = <String, dynamic>{
        'id': 'file',
        'room': '!r:local',
        'content': {
          'parts': [
            {
              'size': 100,
              'file': {'url': 'mxc://local/one'},
            },
            {'size': 300, 'file': {}},
          ],
        },
      };
      expect(actions.pendingStatus(item), 'Загрузка вложения: 25%');
      item['preparing'] = true;
      expect(actions.pendingStatus(item), 'Подготовка вложения…');
      actions.dispose();
    },
  );
  test(
    'Send failures explain known causes without leaking raw exceptions or server secrets',
    () {
      final forbidden = describeSendFailure(
        mx.MatrixException.fromJson({
          'errcode': 'M_FORBIDDEN',
          'error': 'token=secret https://private.example',
        }),
      );
      expect(forbidden.code, 'M_FORBIDDEN');
      expect(forbidden.reason, contains('запретил'));
      expect(forbidden.recommendation, contains('права'));
      final limited = describeSendFailure(
        mx.MatrixException.fromJson({'errcode': 'M_LIMIT_EXCEEDED'}),
      );
      expect(limited.recommendation, contains('автоматически'));
      final timeout = describeSendFailure(
        TimeoutException('https://private.example token=secret'),
      );
      expect(timeout.reason, contains('Истекло'));
      for (final error in [
        StateError('token=secret'),
        mx.MatrixException.fromJson({
          'errcode': 'evil token=secret',
          'error': 'secret',
        }),
      ]) {
        final detail = describeSendFailure(error);
        expect(
          '${detail.reason} ${detail.recommendation} ${detail.code}',
          isNot(contains('secret')),
        );
      }
      expect(
        describeSendFailure(UserActionError('Сократите подпись.')).reason,
        'Сократите подпись.',
      );
    },
  );
  test(
    'Only paired double tildes format; escaping, HTML and incomplete markers remain text',
    () {
      final nodes = parseMessageFormat('before ~~one~~ middle ~~два~~ after');
      expect(
        nodes.map((node) => node.textContent).join(),
        'before one middle два after',
      );
      expect(nodes.whereType<md.Element>().map((node) => node.tag), [
        'del',
        'del',
      ]);
      for (final input in [
        '~single~',
        '~~unclosed',
        '<script>alert(1)</script>',
        '**future**',
      ]) {
        final nodes = parseMessageFormat(input);
        expect(nodes.map((node) => node.textContent).join(), input);
        expect(nodes.whereType<md.Element>(), isEmpty);
      }
      final escaped = parseMessageFormat(r'\~\~literal\~\~');
      expect(escaped.map((node) => node.textContent).join(), '~~literal~~');
      expect(escaped.whereType<md.Element>(), isEmpty);
    },
  );
  test(
    'Personal reactions rank by confirmed frequency, persist and deduplicate retries',
    () async {
      final database = OutboxDatabase();
      final usage = ReactionUsage(database);
      await usage.record('❤️', 'first');
      await usage.record('👍', 'second');
      await usage.record('❤️', 'third');
      await usage.record('👍', 'second');
      expect(usage.frequent.first, '❤️');
      expect(usage.counts['👍'], 1);
      final restored = ReactionUsage(database);
      await restored.load();
      expect(restored.counts, usage.counts);
      await restored.record('❤️', 'third');
      expect(restored.counts['❤️'], 2);
      final other = ReactionUsage(OutboxDatabase());
      await other.load();
      expect(other.frequent, isEmpty);
      for (var i = 0; i < 15; i++) {
        await restored.record('emoji$i', 'txn$i');
      }
      expect(restored.frequent.length, 12);
      database.failWrite = true;
      await expectLater(restored.record('❌', 'failed'), throwsStateError);
      expect(restored.counts.containsKey('❌'), false);
    },
  );
  testWidgets(
    'Strikethrough renders safely with selectable text and existing links',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LinkedText(
              text: 'normal ~~gone~~ https://example.com',
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      );
      final text = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(text.textSpan!.toPlainText(), 'normal gone https://example.com');
      final del = text.textSpan!.children!.whereType<TextSpan>().firstWhere(
        (span) => span.style?.decoration == TextDecoration.lineThrough,
      );
      expect(del.toPlainText(), 'gone');
    },
  );
  testWidgets(
    'Picker animates emoji, includes a red heart and obeys reduced motion',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => pickEmoji(context),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AnimatedEmoji), findsWidgets);
      expect(find.byTooltip('❤️'), findsOneWidget);
      final before = tester
          .widgetList<Transform>(find.byType(Transform))
          .map((widget) => widget.transform.toString())
          .join();
      await tester.pump(const Duration(milliseconds: 240));
      final after = tester
          .widgetList<Transform>(find.byType(Transform))
          .map((widget) => widget.transform.toString())
          .join();
      expect(after, isNot(before));
      await tester.tap(find.byTooltip('❤️'));
      await tester.pumpAndSettle();
      expect(find.byType(AnimatedEmoji), findsNothing);
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: EmojiMotion(child: AnimatedEmoji('❤️')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Transform), findsNothing);
    },
  );
}
