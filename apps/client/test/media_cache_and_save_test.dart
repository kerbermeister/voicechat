import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/file_view.dart';
import 'package:voicechat_probe/message_media_cache.dart';
import 'package:voicechat_probe/transient_notice.dart';
import 'package:voicechat_probe/delete_message_dialog.dart';
import 'screen_panel_test.dart' show PanelDatabase;

void main() {
  test(
    'Avatar cache coalesces concurrent loads, isolates URLs and retries errors',
    () async {
      final cache = MessageMediaCache();
      final first = Uri.parse('mxc://local/one'),
          second = Uri.parse('mxc://local/two');
      var loads = 0;
      final pending = Completer<Uint8List>();
      Future<Uint8List> load() {
        loads++;
        return pending.future;
      }

      final a = cache.loadAvatar(first, load),
          b = cache.loadAvatar(first, load);
      expect(loads, 1);
      pending.complete(Uint8List.fromList([1, 2]));
      expect(await a, same(await b));
      expect(cache.avatar(first), same(await a));
      expect(cache.avatar(second), isNull);
      await cache.loadAvatar(first, () async {
        throw StateError('Should not reload');
      });
      await expectLater(
        cache.loadAvatar(second, () async {
          throw StateError('network');
        }),
        throwsStateError,
      );
      await cache.loadAvatar(second, () async => Uint8List.fromList([3]));
      expect(cache.avatar(second), [3]);
      cache.dispose();
      expect(cache.avatar(first), isNull);
    },
  );
  test(
    'Avatar cache bounds memory and does not resurrect an account after logout',
    () async {
      final cache = MessageMediaCache();
      for (var i = 0; i < 130; i++) {
        await cache.loadAvatar(
          Uri.parse('mxc://local/$i'),
          () async => Uint8List(1),
        );
      }
      expect(cache.avatars.length, 128);
      expect(cache.avatar(Uri.parse('mxc://local/0')), isNull);
      final pending = Completer<Uint8List>();
      final work = cache.loadAvatar(
        Uri.parse('mxc://local/pending'),
        () => pending.future,
      );
      cache.dispose();
      pending.complete(Uint8List(1));
      await work;
      expect(cache.avatars, isEmpty);
    },
  );
  test(
    'Account-scoped cache cannot cross a logout or another client',
    () async {
      final first = mx.Client('cache-first', database: PanelDatabase());
      final second = mx.Client('cache-second', database: PanelDatabase());
      final url = Uri.parse('mxc://local/avatar');
      final a = MessageMediaCache.of(first), b = MessageMediaCache.of(second);
      await a.loadAvatar(url, () async => Uint8List.fromList([1]));
      await b.loadAvatar(url, () async => Uint8List.fromList([2]));
      expect(a.avatar(url), [1]);
      expect(b.avatar(url), [2]);
      MessageMediaCache.clear(first);
      expect(MessageMediaCache.of(first).avatar(url), isNull);
      expect(b.avatar(url), [2]);
      MessageMediaCache.clear(second);
      await first.dispose();
      await second.dispose();
    },
  );
  testWidgets(
    'Cached poster is cloned, survives view disposal, and is bounded',
    (tester) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)
        ..drawRect(
          const Rect.fromLTWH(0, 0, 10, 10),
          Paint()..color = Colors.red,
        );
      expect(canvas, isNotNull);
      final picture = recorder.endRecording();
      final image = await tester.runAsync(() => picture.toImage(10, 10));
      picture.dispose();
      final cache = MessageMediaCache();
      cache.saveFrame('message', image!);
      image.dispose();
      final first = cache.frame('message')!;
      first.dispose();
      final second = cache.frame('message')!;
      expect(second.width, 10);
      cache.saveFrame(
        'expired',
        second,
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      );
      expect(cache.frame('expired'), isNull);
      cache.saveFrame(
        'temporary',
        second,
        expiresAt: DateTime.now().add(const Duration(milliseconds: 100)),
      );
      second.dispose();
      final temporary = cache.frame('temporary');
      expect(temporary, isNotNull);
      temporary?.dispose();
      await tester.pump(const Duration(milliseconds: 150));
      expect(cache.frame('temporary'), isNull);
      for (var i = 0; i < 25; i++) {
        final frame = cache.frame('message');
        if (frame != null) {
          cache.saveFrame('$i', frame);
          frame.dispose();
        }
      }
      cache.dispose();
      expect(cache.frame('message'), isNull);
    },
  );
  testWidgets(
    'Save dialog and cancellation leave the message geometry unchanged',
    (tester) async {
      final dialog = Completer<String?>();
      const channel = MethodChannel('voicechat/save');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'begin');
        return dialog.future;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final client = mx.Client('file-geometry', database: PanelDatabase());
      final room = mx.Room(id: '!test:local', client: client);
      final event = mx.Event.fromJson({
        'event_id': r'$file',
        'sender': '@test:local',
        'type': mx.EventTypes.Message,
        'origin_server_ts': 0,
        'content': {
          'msgtype': 'dev.voicechat.file',
          'body': 'notes.txt',
          'mime': 'text/plain',
          'size': 10,
          'parts': [
            {
              'size': 10,
              'file': {
                'v': 'v2',
                'url': 'mxc://local/file',
                'key': {'k': 'key'},
                'iv': 'iv',
                'hashes': {'sha256': 'hash'},
              },
            },
          ],
        },
      }, room);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: FileView(event: event)),
          ),
        ),
      );
      final before = tester.getRect(find.byType(FileView));
      await tester.tap(find.byTooltip('Сохранить файл'));
      await tester.pump();
      expect(tester.getRect(find.byType(FileView)), before);
      expect(find.byTooltip('Отменить загрузку файла'), findsOneWidget);
      dialog.complete(null);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(FileView)), before);
      expect(find.byTooltip('Сохранить файл'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    },
  );
  testWidgets(
    'Copy notice is compact, replaces previous notices, and disappears',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showTransientNotice(context, 'Скопировано в буфер обмена'),
                child: const Text('Копировать'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Копировать'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getSize(find.byType(SnackBar)).height, lessThan(60));
      await tester.tap(find.text('Копировать'));
      await tester.pumpAndSettle();
      expect(find.text('Скопировано в буфер обмена'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Скопировано в буфер обмена'), findsNothing);
    },
  );
  testWidgets(
    'Delete choices have equal compact geometry and distinct palette colors',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: DeleteMessageDialog(allowAll: true)),
        ),
      );
      final buttons = find.byType(FilledButton);
      expect(buttons, findsNWidgets(3));
      final sizes = [for (var i = 0; i < 3; i++) tester.getSize(buttons.at(i))];
      expect(sizes[0], sizes[1]);
      expect(sizes[1], sizes[2]);
      expect(
        sizes[0].height,
        lessThanOrEqualTo(40),
        reason:
            'button sizes: $sizes; dialog ${tester.getSize(find.byType(AlertDialog))}',
      );
      final colors = [
        for (var i = 0; i < 3; i++)
          tester
              .widget<FilledButton>(buttons.at(i))
              .style!
              .backgroundColor!
              .resolve({}),
      ];
      expect(colors.toSet().length, 3);
      expect(tester.takeException(), isNull);
    },
  );
}
