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
  final events = StreamController<VideoEvent>();
  int plays = 0, disposals = 0;
  Duration? sought;
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    events.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 5),
        size: const Size(320, 320),
      ),
    );
    return 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events.stream;
  @override
  Future<void> play(int playerId) async {
    plays++;
  }

  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
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
    await events.close();
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
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MessageVideo(file: file, inline: true)),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(platform.sought, const Duration(milliseconds: 100));
      expect(platform.plays, 0);
      expect(find.byKey(const ValueKey('decoded-preview')), findsOneWidget);
      await tester.tap(find.byTooltip('Воспроизвести видео'));
      await tester.pump();
      expect(platform.plays, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      expect(platform.disposals, 1);
      await client.dispose();
    },
  );
}
