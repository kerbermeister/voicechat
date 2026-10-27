import 'poster_fixture.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player/video_player.dart';
import 'package:voicechat_probe/message_media_cache.dart';
import 'package:voicechat_probe/video_poster.dart';

// A two-second synthetic red H.264 clip, no camera, microphone or user profile.

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('macOS decoder poster survives closing the real video texture', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'voicechat-poster-',
    );
    final file = File('${directory.path}/preview.mp4');
    await file.writeAsBytes(base64Decode(fixture));
    final player = VideoPlayerController.file(file);
    final cache = MessageMediaCache();
    final key = GlobalKey();
    ui.Image? poster;
    try {
      await player.initialize();
      await player.setVolume(0);
      await player.seekTo(const Duration(milliseconds: 100));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox.square(
                  dimension: 160,
                  child: VideoPlayer(player),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await videoPoster(boundary, player.dataSource);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final center = (image.height ~/ 2 * image.width + image.width ~/ 2) * 4;
      expect(
        data!.getUint8(center),
        greaterThan(180),
        reason: 'Decoded texture must contain the red frame',
      );
      expect(data.getUint8(center + 1), lessThan(80));
      expect(player.value.isPlaying, false);
      cache.saveFrame('note', image);
      image.dispose();
      poster = cache.frame('note')!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RawImage(image: poster, width: 160, height: 160),
            ),
          ),
        ),
      );
      await player.dispose();
      await tester.pump();
      final retained = await poster.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      expect(retained!.getUint8(center), greaterThan(180));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    } finally {
      await player.dispose();
      poster?.dispose();
      cache.dispose();
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);
}
