import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'link_platform.dart';

class EmbeddedVideo extends StatelessWidget {
  final String id;
  const EmbeddedVideo({super.key, required this.id});
  @override
  Widget build(BuildContext context) {
    if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) {
      throw const FormatException('Invalid video id');
    }
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return Center(
        child: TextButton.icon(
          icon: const Icon(Icons.open_in_new),
          label: const Text('Открыть видео в браузере'),
          onPressed: () async {
            try {
              await openLink(Uri.https('www.youtube.com', '/watch', {'v': id}));
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Не удалось открыть браузер. Повторите попытку.',
                    ),
                  ),
                );
              }
            }
          },
        ),
      );
    }
    return AndroidView(
      viewType: 'voicechat/youtube',
      creationParams: id,
      creationParamsCodec: const StandardMessageCodec(),
    );
  }
}
