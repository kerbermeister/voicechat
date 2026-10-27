import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:web/web.dart' as web;

Future<ui.Image> videoPoster(
  RenderRepaintBoundary boundary,
  String source,
) async {
  // HTML video is outside Flutter's paint tree. Match its unique decrypted URL.
  web.HTMLVideoElement? video;
  final videos = web.document.querySelectorAll('video');
  for (var index = 0; index < videos.length; index++) {
    final element = videos.item(index);
    if (element == null || !element.isA<web.HTMLVideoElement>()) continue;
    final candidate = element as web.HTMLVideoElement;
    if (candidate.currentSrc == source || candidate.src == source) {
      video = candidate;
      break;
    }
  }
  if (video == null ||
      video.readyState < 2 ||
      video.videoWidth == 0 ||
      video.videoHeight == 0) {
    throw StateError('Video frame is not ready');
  }
  final width = math.min(330, video.videoWidth);
  final canvas = web.HTMLCanvasElement()
    ..width = width
    ..height = (width * video.videoHeight / video.videoWidth).round();
  canvas.context2D.drawImage(video, 0, 0, canvas.width, canvas.height);
  final bytes = base64Decode(canvas.toDataURL('image/png').split(',').last);
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}
