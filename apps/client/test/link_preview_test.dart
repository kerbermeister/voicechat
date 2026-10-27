import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/link_preview.dart';
import 'package:voicechat_probe/link_cards.dart';
import 'package:voicechat_probe/theme.dart';
import 'chat_actions_test.dart' show OutboxDatabase, OutboxRoom;

void main() {
  test('Embedded video only accepts an exact YouTube host and video id', () {
    for (final url in [
      'https://youtu.be/abcdefghijk',
      'https://www.youtube.com/watch?v=abcdefghijk',
      'https://youtube.com/shorts/abcdefghijk',
    ]) {
      expect(youtubeVideoId(Uri.parse(url)), 'abcdefghijk');
    }
    for (final url in [
      'https://youtube.com.evil.invalid/watch?v=abcdefghijk',
      'https://youtube.com/watch?v=<script>',
      'https://youtu.be/abc/def',
    ]) {
      expect(youtubeVideoId(Uri.parse(url)), isNull);
    }
  });
  test(
    'Links are deduplicated, bounded and never accept credentials or script schemes',
    () {
      expect(
        messageLinks(
          'https://example.com/a, https://example.com/a https://user:secret@example.com javascript:alert(1)',
        ),
        [Uri.parse('https://example.com/a')],
      );
      expect(
        messageLinks(
          List.generate(10, (i) => 'https://example.com/$i').join(' '),
        ).length,
        3,
      );
    },
  );
  test(
    'Previews must belong to current text; malformed and obsolete cards are ignored',
    () {
      final card = {
        'url': 'https://example.com/a',
        'title': 'Title',
        'description': 'Description',
        'image': 'not base64',
      };
      expect(
        messagePreviews('https://example.com/a', [card]).single.image,
        isNull,
      );
      expect(messagePreviews('edited text without link', [card]), isEmpty);
      expect(
        messagePreviews('https://example.com/a', [
          {'url': 'file:///private'},
          null,
        ]),
        isEmpty,
      );
    },
  );
  test(
    'Preview stays in the durable encrypted outbox and disappears when its URL is edited out',
    () async {
      final database = OutboxDatabase();
      final client = Client(
        'links-test',
        database: database,
        httpClient: MockClient((_) async => http.Response('{}', 503)),
        logLevel: Level.error,
      );
      final queue = ChatActions(client);
      await queue.open();
      final card = LinkPreview(
        Uri.parse('https://example.com/a'),
        'Private title',
        'Private description',
        null,
      );
      await queue.text(
        OutboxRoom(client),
        'https://example.com/a',
        previews: [card],
      );
      await queue.text(
        OutboxRoom(client),
        'Edited without link',
        previews: [card],
        edit: '\$original',
      );
      final saved =
          database.values['dev.voicechat.local.outbox']!['items'] as List;
      expect(jsonEncode(saved.first), contains('Private title'));
      expect(jsonEncode(saved.last), isNot(contains('Private title')));
      await queue.close();
    },
  );
  testWidgets('Editing or removing a URL removes its obsolete playable card', (
    tester,
  ) async {
    Future<void> render(String text) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LinkCards(
            text: text,
            previews: const [
              {
                'url': 'https://example.com/a.mp4',
                'title': 'Old clip',
                'description': '',
              },
            ],
          ),
        ),
      ),
    );
    await render('https://example.com/a.mp4');
    expect(find.text('Old clip'), findsOneWidget);
    expect(find.text('Смотреть видео'), findsNothing);
    expect(find.byType(InkWell), findsWidgets);
    await render('https://example.com/new.txt');
    expect(find.text('Old clip'), findsNothing);
    expect(find.text('Смотреть видео'), findsNothing);
    await render('Link removed');
    expect(find.byType(LinkCards), findsOneWidget);
    expect(find.text('Old clip'), findsNothing);
  });
  testWidgets('Link cards fit narrow layouts in all seven themes', (
    tester,
  ) async {
    final url = 'https://example.com/video.mp4';
    for (final palette in AppPalette.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: palette.theme,
          home: Scaffold(
            body: SizedBox(
              width: 260,
              child: LinkCards(
                text: url,
                previews: [
                  {
                    'url': url,
                    'title': 'Long title ' * 12,
                    'description': 'Description ' * 30,
                  },
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('Смотреть видео'), findsNothing);
      expect(find.byType(InkWell), findsWidgets);
      expect(tester.takeException(), isNull);
    }
  });
}
