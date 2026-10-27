import 'dart:async';
import 'package:flutter/material.dart';
import 'embedded_video_native.dart'
    if (dart.library.js_interop) 'embedded_video_web.dart'
    as platform;
import 'message_playback.dart';

class EmbeddedVideo extends StatefulWidget {
  final String id;
  const EmbeddedVideo({super.key, required this.id});
  @override
  State<EmbeddedVideo> createState() => _EmbeddedVideoState();
}

class _EmbeddedVideoState extends State<EmbeddedVideo> {
  bool active = false;
  @override
  void initState() {
    super.initState();
    unawaited(start());
  }

  Future<void> pause() async {
    if (!mounted) return;
    setState(() => active = false);
    // Remove the iframe/platform view before another message starts playing.
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> start() async {
    try {
      await messagePlayback.start(
        this,
        messagePlayback.request(this),
        () async {
          if (mounted) setState(() => active = true);
        },
        pause,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось остановить предыдущее воспроизведение. Повторите попытку.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => active
      ? platform.EmbeddedVideo(id: widget.id)
      : Center(
          child: TextButton.icon(
            onPressed: start,
            icon: const Icon(Icons.play_circle_outline),
            label: const Text('Воспроизвести видео'),
          ),
        );
  @override
  void dispose() {
    unawaited(messagePlayback.pause(this));
    super.dispose();
  }
}
