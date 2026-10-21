import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

class EmbeddedVideo extends StatefulWidget {
  final String id;
  const EmbeddedVideo({super.key, required this.id});
  @override
  State<EmbeddedVideo> createState() => _EmbeddedVideoState();
}

class _EmbeddedVideoState extends State<EmbeddedVideo> {
  web.HTMLIFrameElement? frame;
  @override
  Widget build(BuildContext context) {
    if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(widget.id)) {
      throw const FormatException('Invalid video id');
    }
    return HtmlElementView.fromTagName(
      tagName: 'iframe',
      onElementCreated: (element) {
        final next = element as web.HTMLIFrameElement;
        frame = next;
        next
          ..title = 'YouTube · видеоплеер'
          ..src =
              'https://www.youtube-nocookie.com/embed/${widget.id}?autoplay=0&playsinline=1'
          ..referrerPolicy = 'strict-origin-when-cross-origin'
          ..allow = 'encrypted-media; picture-in-picture; fullscreen';
        next.setAttribute('credentialless', '');
        next.setAttribute(
          'sandbox',
          'allow-scripts allow-same-origin allow-presentation',
        );
        next.style
          ..border = '0'
          ..width = '100%'
          ..height = '100%';
      },
    );
  }

  @override
  void dispose() {
    frame?.src = 'about:blank';
    frame?.remove();
    super.dispose();
  }
}
