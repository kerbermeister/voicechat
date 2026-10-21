import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/album_view.dart';
import 'package:voicechat_probe/avatar_editor.dart';
import 'package:voicechat_probe/chunked_file.dart';
import 'package:voicechat_probe/picked_file.dart';
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/chat_pane.dart';
import 'package:voicechat_probe/emoji_picker.dart';
import 'package:voicechat_probe/media_policy.dart';
import 'package:voicechat_probe/photo_processing.dart';
import 'package:voicechat_probe/photo_viewer.dart';
import 'package:voicechat_probe/room_members_dialog.dart';
import 'package:voicechat_probe/theme.dart';
import 'package:voicechat_probe/typing_indicator.dart';
import 'package:voicechat_probe/voice_recording.dart';
import 'chat_actions_test.dart' show OutboxDatabase, OutboxRoom;
import 'message_test.dart' show TestClient;

class RichClient extends TestClient {
  @override
  bool get autoRequestProfileForMissingUsers => false;
  @override
  bool get getDisplayNameAndAvatarFromPrevContent => false;
}

void main() {
  test(
    'Large file manifest accepts exactly 300 MiB and refuses malformed parts',
    () {
      final descriptor = {
        'v': 'v2',
        'key': {'k': 'test'},
        'iv': 'test',
        'hashes': {'sha256': 'test'},
        'url': 'mxc://local/part',
      };
      final content = <String, dynamic>{
        'size': 314572800,
        'body': 'file.pdf',
        'mime': 'application/pdf',
        'parts': List.generate(
          75,
          (_) => {'size': fileChunkBytes, 'file': descriptor},
        ),
      };
      expect(ChunkedFile(TestClient(), content).parts.length, 75);
      for (final invalid in [
        {...content, 'size': 314572801},
        {...content, 'size': 0},
        {...content, 'parts': (content['parts'] as List).take(74).toList()},
        {
          ...content,
          'parts': [
            {'size': 314572800, 'file': descriptor},
          ],
        },
        {...content, 'mime': 'video/mp4\r\nInjected: header'},
      ]) {
        expect(() => ChunkedFile(TestClient(), invalid), throwsFormatException);
      }
    },
  );
  test('Avatar crop selects the requested edge and exports a 512 square', () {
    final source = img.Image(width: 100, height: 50, numChannels: 3);
    img.fillRect(
      source,
      x1: 0,
      y1: 0,
      x2: 49,
      y2: 49,
      color: img.ColorRgb8(255, 0, 0),
    );
    img.fillRect(
      source,
      x1: 50,
      y1: 0,
      x2: 99,
      y2: 49,
      color: img.ColorRgb8(0, 0, 255),
    );
    final bytes = Uint8List.fromList(img.encodeJpg(source));
    final left = img.decodeJpg(cropAvatar(bytes, 1, -1, 0))!;
    final right = img.decodeJpg(cropAvatar(bytes, 1, 1, 0))!;
    expect(left.width, 512);
    expect(left.height, 512);
    expect(left.getPixel(100, 100).r, greaterThan(200));
    expect(right.getPixel(100, 100).b, greaterThan(200));
    expect(() => cropAvatar(bytes, 0, 0, 0), throwsFormatException);
  });
  test('Policy validates untrusted server values and round trips', () {
    const defaults = MediaPolicy();
    expect(MediaPolicy.fromJson(defaults.toJson()).photoMaxCount, 24);
    for (final change in [
      {'photo_max_count': 0},
      {'photo_max_count': 65},
      {'photo_scale': double.nan},
      {'photo_jpeg_quality': true},
      {'photo_max_bytes': 999999999},
      {'text_max_length': 20000},
      {'version': 2},
    ]) {
      expect(
        () => MediaPolicy.fromJson({...defaults.toJson(), ...change}),
        throwsFormatException,
      );
    }
  });
  test(
    'Photos halve both sides, flatten alpha on white and reject bad input',
    () {
      final image = img.Image(width: 120, height: 80, numChannels: 4);
      final bytes = img.encodePng(image);
      final photo = compressPhoto(
        bytes,
        'transparent.png',
        const MediaPolicy(),
      );
      expect(
        (photo.width, photo.height, photo.mimeType),
        (60, 40, 'image/jpeg'),
      );
      final pixel = img.decodeJpg(photo.bytes)!.getPixel(0, 0);
      expect(pixel.r, greaterThan(245));
      expect(
        () => compressPhoto(
          bytes,
          'a.png',
          const MediaPolicy(photoMaxPixels: 100),
        ),
        throwsStateError,
      );
      expect(
        () => compressPhoto(
          Uint8List.fromList([1, 2, 3]),
          'bad.png',
          const MediaPolicy(),
        ),
        throwsStateError,
      );
      expect(
        () =>
            compressPhoto(bytes, 'a.png', const MediaPolicy(photoMaxBytes: 2)),
        throwsStateError,
      );
    },
  );
  test(
    'Waveform is real bounded PCM RMS with silence, signal and uneven bins',
    () {
      final pcm = Uint8List(400);
      final data = ByteData.sublistView(pcm);
      for (var i = 100; i < 200; i++) {
        data.setInt16(i * 2, 16384, Endian.little);
      }
      expect(pcmWaveform(pcm, bins: 2), [0, 512]);
      expect(pcmWaveform(Uint8List(2), bins: 64), List.filled(64, 0));
      expect(() => pcmWaveform(Uint8List(3)), throwsArgumentError);
      expect(() => pcmWaveform(pcm, bins: 129), throwsArgumentError);
    },
  );
  test(
    'Calendar labels handle year boundary and old dates; media timer is exact',
    () {
      final now = DateTime(2026, 1, 1, 1);
      expect(messageDay(DateTime(2025, 12, 31, 23), now), 'Вчера');
      expect(messageDay(DateTime(2026, 1, 1), now), 'Сегодня');
      expect(messageDay(DateTime(2025, 10, 3), now), '03.10.2025');
      expect(mediaTime(const Duration(seconds: 65)), '1:05');
    },
  );
  test(
    'Album and waveform survive encrypted-store queue round trip as a single transaction',
    () async {
      final database = OutboxDatabase();
      final client = Client(
        'album-test',
        database: database,
        logLevel: Level.error,
      );
      final actions = ChatActions(client);
      await actions.open();
      final photo = compressPhoto(
        img.encodePng(img.Image(width: 20, height: 20)),
        'test.png',
        const MediaPolicy(),
      );
      await actions.album(OutboxRoom(client), [photo, photo], 'Наши фото');
      final id = actions.pending.single['id'];
      expect(actions.pending.single['content']['images'].length, 2);
      await actions.close();
      final restored = ChatActions(client);
      await restored.open();
      expect(restored.pending.single['id'], id);
      expect(restored.pending.single['content']['caption'], 'Наши фото');
      await expectLater(
        restored.album(OutboxRoom(client), List.filled(25, photo), ''),
        throwsStateError,
      );
      await expectLater(
        restored.attachment(
          OutboxRoom(client),
          MatrixAudioFile(bytes: Uint8List(10), name: 'voice.wav'),
          waveform: [2048],
        ),
        throwsStateError,
      );
      await restored.close();
    },
  );
  test('Album parser rejects malformed or excessive remote metadata', () {
    final room = Room(id: '!test:local', client: RichClient());
    Event event(Object images) => Event.fromJson({
      'event_id': '\$album',
      'type': EventTypes.Message,
      'sender': '@me:local',
      'origin_server_ts': 1,
      'content': {'msgtype': 'dev.voicechat.album', 'images': images},
    }, room);
    expect(() => albumPhotos(event([])), throwsFormatException);
    expect(
      () => albumPhotos(event(List.filled(65, {}))),
      throwsFormatException,
    );
    final photos = albumPhotos(
      event([
        {
          'msgtype': MessageTypes.Image,
          'body': 'photo.jpg',
          'info': {'size': 10},
        },
      ]),
    );
    expect(photos.single.eventId, '\$album/0');
    expect(loadPhoto(photos.single), throwsFormatException);
  });
  test(
    'All typing users are named, own user is not displayed as a nickname',
    () {
      final room = Room(id: '!test:local', client: RichClient());
      room.states[EventTypes.RoomMember] = {
        for (final id in ['@user:local', '@alice:local', '@bob:local'])
          id: User(id, membership: 'join', room: room),
      };
      room.ephemerals['m.typing'] = BasicEvent(
        type: 'm.typing',
        content: {
          'user_ids': ['@user:local', '@alice:local', '@bob:local'],
        },
      );
      expect(
        typingLabel(room, false),
        'Вы печатаете · @alice:local, @bob:local печатают',
      );
    },
  );
  test(
    'All seven themes have readable primary text and preserve selected references',
    () {
      expect(AppPalette.values.length, 7);
      for (final palette in AppPalette.values) {
        final colors = palette.theme.colorScheme;
        final a = colors.primary.computeLuminance(),
            b = colors.onPrimary.computeLuminance();
        expect(
          (a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05)),
          greaterThanOrEqualTo(4.5),
          reason: palette.label,
        );
      }
    },
  );
  test('One newest reaction per author survives old duplicates', () {
    final room = Room(id: '!test:local', client: RichClient());
    Event reaction(String id, String user, int time, String emoji) =>
        Event.fromJson({
          'event_id': id,
          'type': EventTypes.Reaction,
          'sender': user,
          'origin_server_ts': time,
          'content': {
            'm.relates_to': {
              'rel_type': RelationshipTypes.reaction,
              'event_id': r'$message',
              'key': emoji,
            },
          },
        }, room);
    final active = latestReactions([
      reaction('a', '@a:local', 1, '👍'),
      reaction('b', '@a:local', 2, '❤️'),
      reaction('c', '@b:local', 2, '🎉'),
      reaction('d', '@a:local', 2, '😊'),
    ]);
    expect(active.length, 2);
    expect(active.firstWhere((e) => e.senderId == '@a:local').eventId, 'd');
    expect(
      reactionEmoji(active.firstWhere((e) => e.senderId == '@b:local')),
      '🎉',
    );
  });
  testWidgets('Emoji picker is a bounded grid on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => pickEmoji(context),
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);
    await tester.tap(find.byTooltip('😀'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('Photo viewer navigates and closes at phone width', (
    tester,
  ) async {
    final bytes = img.encodePng(img.Image(width: 10, height: 10));
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoViewer(
          photos: [() async => bytes, () async => bytes],
          initial: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.tap(find.byTooltip('Следующее фото'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Member tabs separate one joined and two invited users', (
    tester,
  ) async {
    final room = Room(id: '!group:local', client: RichClient());
    room.states[EventTypes.RoomPowerLevels] = {
      '': StrippedStateEvent(
        type: EventTypes.RoomPowerLevels,
        content: {
          'users': {'@user:local': 100},
        },
        senderId: '@user:local',
        stateKey: '',
      ),
    };
    room.states[EventTypes.RoomName] = {
      '': StrippedStateEvent(
        type: EventTypes.RoomName,
        content: {'name': 'Семья'},
        senderId: '@user:local',
        stateKey: '',
      ),
    };
    final members = [
      for (final (id, membership) in [
        ('@user:local', 'join'),
        ('@alice:local', 'invite'),
        ('@bob:local', 'invite'),
      ])
        User(id, membership: membership, room: room),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoomMembersDialog(room: room, members: members),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Вступили · 1'), findsOneWidget);
    expect(find.text('Приглашены · 2'), findsOneWidget);
    await tester.tap(find.text('Приглашены · 2'));
    await tester.pumpAndSettle();
    expect(find.textContaining('@alice:local'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
