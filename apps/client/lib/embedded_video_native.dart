import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class EmbeddedVideo extends StatelessWidget {
  final String id;
  const EmbeddedVideo({super.key, required this.id});
  @override
  Widget build(BuildContext context) {
    if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) {
      throw const FormatException('Invalid video id');
    }
    return AndroidView(
      viewType: 'voicechat/youtube',
      creationParams: id,
      creationParamsCodec: const StandardMessageCodec(),
    );
  }
}
