// New adversarial combinations, independent of user accounts and real devices.
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/album_view.dart';
import 'package:voicechat_probe/file_view.dart';
import 'package:voicechat_probe/media_key_clock.dart';
import 'package:voicechat_probe/message_media_cache.dart';
import 'package:voicechat_probe/message_playback.dart';
import 'package:voicechat_probe/p2p/archive.dart';

import '../../../apps/client/test/conversation_list_test.dart' show ListClient;

Future<Uint8List> collect(Stream<Uint8List> stream) async {
  final out = BytesBuilder();
  await for (final bytes in stream) {
    out.add(bytes);
  }
  return out.takeBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'UA-53.C05 late avatar completion cannot refill a cleared account cache',
    () async {
      final account = ListClient();
      final old = MessageMediaCache.of(account);
      final pending = Completer<Uint8List>();
      final uri = Uri.parse('mxc://qa/avatar');
      final oldLoad = old.loadAvatar(uri, () => pending.future);
      MessageMediaCache.clear(account);
      final current = MessageMediaCache.of(account);
      await current.loadAvatar(uri, () async => Uint8List.fromList([2]));
      pending.complete(Uint8List.fromList([1]));
      await oldLoad;
      expect(old.avatar(uri), isNull);
      expect(current.avatar(uri), [2]);
      MessageMediaCache.clear(account);
    },
  );
  test(
    'UA-53.C06 identical media URI remains isolated between two accounts',
    () async {
      final a = ListClient(), b = ListClient();
      final uri = Uri.parse('mxc://qa/same');
      await MessageMediaCache.of(a)
          .loadAvatar(uri, () async => Uint8List.fromList([1]));
      await MessageMediaCache.of(b)
          .loadAvatar(uri, () async => Uint8List.fromList([2]));
      MessageMediaCache.clear(a);
      expect(MessageMediaCache.of(b).avatar(uri), [2]);
      MessageMediaCache.clear(b);
    },
  );
  test(
    'UA-53.C07 129 avatars evict the oldest, touching one retains it',
    () async {
      final cache = MessageMediaCache();
      for (var i = 0; i < 128; i++) {
        await cache.loadAvatar(
          Uri.parse('mxc://qa/$i'),
          () async => Uint8List.fromList([i]),
        );
      }
      cache.avatar(Uri.parse('mxc://qa/0'));
      await cache.loadAvatar(
        Uri.parse('mxc://qa/128'),
        () async => Uint8List.fromList([128]),
      );
      expect(cache.avatar(Uri.parse('mxc://qa/0')), [0]);
      expect(cache.avatar(Uri.parse('mxc://qa/1')), isNull);
      expect(cache.avatars.length, 128);
      cache.dispose();
    },
  );
  test(
    'UA-55.C05 100 superseded playback requests only start the final owner',
    () async {
      final lane = MessagePlayback();
      final calls = <int>[];
      final results = <Future<bool>>[];
      final owners = List.generate(100, (_) => Object());
      for (var i = 0; i < owners.length; i++) {
        results.add(
          lane.start(owners[i], lane.request(owners[i]), () async {
            calls.add(i);
          }, () async {}),
        );
      }
      final accepted = await Future.wait(results);
      expect(calls, [99]);
      expect(accepted.where((v) => v).length, 1);
      await lane.pause(owners.last);
    },
  );
  test(
    'UA-55.C06 close of old player while next is queued cannot cancel the next',
    () async {
      final lane = MessagePlayback(), old = Object(), next = Object();
      final release = Completer<void>();
      await lane.start(
        old,
        lane.request(old),
        () async {},
        () => release.future,
      );
      var played = false;
      final replacement = lane.start(next, lane.request(next), () async {
        played = true;
      }, () async {});
      await Future<void>.delayed(Duration.zero);
      lane.closed(old);
      release.complete();
      expect(await replacement, true);
      expect(played, true);
      await lane.pause(next);
    },
  );
  test('UA-69.C07 ZIP sanitizes colliding case-insensitive and traversal names independently', () async {
    final files = ['../x', '..\\x', 'FILE', 'file', '2-file', '.', '']
        .asMap()
        .entries
        .map(
          (entry) => (
            name: entry.value,
            size: 1,
            read: (int from, int to) =>
                Stream.value(Uint8List.fromList([entry.key]).sublist(from, to)),
          ),
        )
        .toList();
    final zip = await P2pArchive.create(files, () => false);
    final decoded = ZipDecoder().decodeBytes(
      await collect(zip.range(0, zip.size)),
    );
    final names = decoded.files.map((f) => f.name).toList();
    expect(names.map((s) => s.toLowerCase()).toSet().length, files.length);
    expect(names.any((s) => s.contains('/') || s.contains('\\')), false);
    for (var i = 0; i < files.length; i++) {
      expect(decoded.files[i].content, [i]);
    }
  });
  test('UA-69.C08 200 random ZIP ranges match the same full archive', () async {
    final payload = Uint8List.fromList(List.generate(4097, (i) => i % 251));
    final zip = await P2pArchive.create([
      (
        name: 'qa.bin',
        size: payload.length,
        read: (int from, int to) =>
            Stream.value(Uint8List.sublistView(payload, from, to)),
      ),
    ], () => false);
    final full = await collect(zip.range(0, zip.size));
    final random = Random(20261101);
    for (var i = 0; i < 200; i++) {
      final start = random.nextInt(zip.size + 1);
      final end = start + random.nextInt(zip.size - start + 1);
      expect(await collect(zip.range(start, end)), full.sublist(start, end));
    }
  });
  test('UA-69.C09 cancellation during ZIP verification yields no completed archive', () async {
    var cancelled = false;
    Stream<Uint8List> read(int from, int to) async* {
      yield Uint8List(1);
      cancelled = true;
      yield Uint8List(1);
    }

    await expectLater(
      P2pArchive.create([(name: 'qa', size: 2, read: read)], () => cancelled),
      throwsStateError,
    );
  });
  test('UA-04.C13 1000 media-key lifetime boundaries use server time despite wall clock skew', () {
    final random = Random(44);
    for (var i = 0; i < 1000; i++) {
      final offset = random.nextInt(180001) - 60000;
      final expiry = 1000000 + offset;
      final accepted = validMediaKeyLifetime(
        {'server_expires_at': expiry, 'expires_at': 999999999},
        now: i.isEven ? 0 : 9999999999,
        serverNow: 1000000,
      );
      expect(accepted, offset > 0 && offset <= 60000);
    }
    expect(
      validMediaKeyLifetime({'server_expires_at': 1000001}, now: 0),
      false,
    );
  });
  final malformed = <Map<String, dynamic>>[
    {},
    {'size': null, 'parts': []},
    {'size': 1, 'parts': 'bad'},
    {'size': -1, 'parts': []},
    {'size': 314572801, 'parts': []},
    {
      'size': 1,
      'parts': [null],
    },
    {
      'size': 1,
      'parts': [{}],
      'body': 42,
    },
    {
      'size': 1,
      'parts': [{}],
      'body': 'a',
      'mime': 'x\r\ny',
    },
  ];
  for (var i = 0; i < malformed.length; i++) {
    testWidgets(
      'UA-63.C05 malformed chunk manifest $i shows bounded UI error',
      (tester) async {
        final room = Room(id: '!qa:local', client: ListClient());
        final event = Event.fromJson({
          'type': EventTypes.Message,
          'event_id': r'$qa',
          'sender': '@qa:local',
          'content': {'msgtype': 'dev.voicechat.file', ...malformed[i]},
        }, room);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: FileView(event: event)),
          ),
        );
        expect(find.text('Некорректное вложение'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'UA-19.C05 mixed malformed album list displays an error without crashing its chat',
    (tester) async {
      final room = Room(id: '!qa:local', client: ListClient());
      final event = Event.fromJson({
        'type': EventTypes.Message,
        'event_id': r'$qa',
        'sender': '@qa:local',
        'content': {
          'msgtype': 'dev.voicechat.album',
          'images': [{}, null, 'bad'],
        },
      }, room);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AlbumView(event: event)),
        ),
      );
      expect(find.text('Повреждённый альбом'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
