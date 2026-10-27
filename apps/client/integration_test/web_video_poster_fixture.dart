import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:video_player/video_player.dart';
import 'package:voicechat_probe/message_media_cache.dart';
import 'package:voicechat_probe/video_poster.dart';
import 'poster_fixture.dart';

void main() => runApp(const MaterialApp(home: PosterFixture()));

class PosterFixture extends StatefulWidget {
  const PosterFixture({super.key});
  @override
  State<PosterFixture> createState() => _PosterFixtureState();
}

class _PosterFixtureState extends State<PosterFixture> {
  final key = GlobalKey();
  final cache = MessageMediaCache();
  VideoPlayerController? player;
  ui.Image? poster;
  String status = 'Синтетический тест кадра';
  bool busy = false;
  Future<void> check() async {
    setState(() {
      busy = true;
      status = 'Декодирование';
    });
    try {
      final video = VideoPlayerController.networkUrl(
        Uri.dataFromBytes(base64Decode(fixture), mimeType: 'video/mp4'),
      );
      player = video;
      await video.initialize();
      await video.setVolume(0);
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      await video.seekTo(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await WidgetsBinding.instance.endOfFrame;
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final frame = await videoPoster(boundary, video.dataSource);
      final rgba = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
      final center = (frame.height ~/ 2 * frame.width + frame.width ~/ 2) * 4;
      final red = rgba!.getUint8(center), green = rgba.getUint8(center + 1);
      if (red < 180 || green > 80 || video.value.isPlaying) {
        throw StateError('Некорректный кадр: $red/$green');
      }
      cache.saveFrame('note', frame);
      frame.dispose();
      poster = cache.frame('note');
      await video.dispose();
      setState(() {
        player = null;
        status = 'Проверка пройдена: кадр сохранён, плеер закрыт, звука нет';
      });
    } catch (error) {
      setState(() => status = 'Ошибка: $error');
    } finally {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(status),
          FilledButton(
            onPressed: busy ? null : check,
            child: const Text('Проверить кадр'),
          ),
          if (player?.value.isInitialized == true)
            RepaintBoundary(
              key: key,
              child: SizedBox.square(
                dimension: 160,
                child: VideoPlayer(player!),
              ),
            ),
          if (poster != null) RawImage(image: poster, width: 160, height: 160),
        ],
      ),
    ),
  );
  @override
  void dispose() {
    player?.dispose();
    poster?.dispose();
    cache.dispose();
    super.dispose();
  }
}
