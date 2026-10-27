import 'package:voicechat_probe/message_media_cache.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
// Uses the interface already supplied by video_player to verify playback requests.
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:voicechat_probe/chunked_file.dart';
import 'package:voicechat_probe/file_view.dart';
import 'screen_panel_test.dart' show PanelDatabase;

class PreviewPlayer extends VideoPlayerPlatform {
  final events = <int, StreamController<VideoEvent>>{};
  int created = 0;
  int plays = 0, disposals = 0;
  Duration? sought;
  final volumes = <double>[];
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = ++created;
    events[id] = StreamController<VideoEvent>();
    events[id]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 5),
        size: const Size(320, 320),
      ),
    );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events[playerId]!.stream;
  @override
  Future<void> play(int playerId) async {
    plays++;
  }

  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {
    volumes.add(volume);
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {
    sought = position;
  }

  @override
  Future<Duration> getPosition(int playerId) async => sought ?? Duration.zero;
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const ColoredBox(key: ValueKey('decoded-preview'), color: Colors.red);
  @override
  Future<void> dispose(int playerId) async {
    disposals++;
    await events.remove(playerId)!.close();
  }
}

void main() {
  testWidgets(
    'Видеокружок декодирует кадр до нажатия без автозвука и начинает видео по кнопке',
    (tester) async {
      final previous = VideoPlayerPlatform.instance;
      final platform = PreviewPlayer();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      final client = Client('video-preview', database: PanelDatabase());
      final file = ChunkedFile(client, {
        'body': 'note.mp4',
        'mime': 'video/mp4',
        'size': 10,
        'video_note': true,
        'parts': [
          {
            'size': 10,
            'file': {
              'v': 'v2',
              'url': 'mxc://local/note',
              'key': {'k': 'key'},
              'iv': 'iv',
              'hashes': {'sha256': 'hash'},
            },
          },
        ],
      });
      final room = Room(id: '!video:local', client: client);
      final event = Event.fromJson({
        'type': EventTypes.Message,
        'event_id': r'$video',
        'sender': '@peer:local',
        'origin_server_ts': 1,
        'content': {...file.content, 'msgtype': 'dev.voicechat.file'},
      }, room);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FileView(event: event, volume: .35)),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(platform.sought, const Duration(milliseconds: 100));
      expect(platform.plays, 0);
      expect(platform.volumes.last, .35);
      expect(find.text('Видеокружок'), findsNothing);
      expect(find.textContaining('МБ'), findsNothing);
      expect(tester.getSize(find.byType(FileView)).width, 220);
      final circles = find.byType(ClipOval).first;
      expect(tester.getSize(circles).width, 220);
      expect(tester.getSize(find.byType(FileView)).height, 220);

      final play = tester.getRect(find.byTooltip('Воспроизвести видео'));
      final circle = tester.getRect(find.byType(MessageVideo));
      expect((play.center - circle.center).distance, lessThan(.1));
      expect(find.byTooltip('Сохранить файл'), findsNothing);

      expect(find.byKey(const ValueKey('decoded-preview')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      final retained = MessageMediaCache.of(
        client,
      ).frame('${room.id}/${event.eventId}');
      expect(retained, isNotNull);
      retained!.dispose();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FileView(event: event, volume: .35)),
        ),
      );
      await tester.pump();
      expect(
        platform.created,
        1,
        reason: 'Returning to a cached circle must not reopen its decoder',
      );
      expect(find.byType(RawImage), findsOneWidget);
      expect(platform.plays, 0);
      await tester.tap(find.byTooltip('Воспроизвести видео'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      expect(platform.plays, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FileView(event: event, volume: 0)),
        ),
      );
      await tester.pump();
      expect(platform.volumes.last, 0);
      expect(platform.plays, 1);
      await tester.tapAt(
        tester.getCenter(find.byType(MessageVideo)) + const Offset(60, 0),
      );
      await tester.pump();
      unawaited(showFileInfo(tester.element(find.byType(FileView)), event));
      await tester.pumpAndSettle();
      expect(find.text('Информация'), findsOneWidget);
      expect(find.textContaining('video/mp4'), findsOneWidget);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      expect(platform.disposals, 2);
      await client.dispose();
    },
  );
}
