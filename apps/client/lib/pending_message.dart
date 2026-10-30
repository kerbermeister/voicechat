import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'link_cards.dart';
import 'waveform_view.dart';

/// One stable card per outbox transaction, replaced only by its confirmed event.
class PendingMessageContent extends StatefulWidget {
  const PendingMessageContent({super.key, required this.content});
  final Map content;
  @override
  State<PendingMessageContent> createState() => _PendingMessageContentState();
}

class _PendingMessageContentState extends State<PendingMessageContent> {
  Uint8List? thumbnail;
  @override
  void initState() {
    super.initState();
    cacheImage();
  }

  @override
  void didUpdateWidget(PendingMessageContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    cacheImage();
  }

  void cacheImage() {
    if (thumbnail != null) return;
    final content = widget.content;
    final images = content['images'];
    final encoded = content['msgtype'] == 'm.image'
        ? content['bytes']
        : images is List && images.isNotEmpty && images.first is Map
        ? images.first['bytes']
        : null;
    if (encoded is String) {
      try {
        thumbnail = base64Decode(encoded);
      } catch (_) {
        /* Display the filename if an old draft has no usable preview. */
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.content;
    final type = content['msgtype'];
    final caption = content['caption'] ?? content['dev.voicechat.caption'];
    final waveform = content['dev.voicechat.waveform'];
    final body = content['body'] as String? ?? 'Сообщение';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (type == 'm.text')
          LinkedText(
            text: body,
            selectable: false,
            style: Theme.of(context).textTheme.bodyMedium!,
          )
        else
          Row(
            children: [
              Icon(
                type == 'm.audio'
                    ? Icons.mic
                    : type == 'dev.voicechat.album' || type == 'm.image'
                    ? Icons.photo_outlined
                    : content['video_note'] == true ||
                          (content['mime'] as String? ?? '').startsWith(
                            'video/',
                          )
                    ? Icons.videocam_outlined
                    : Icons.insert_drive_file_outlined,
              ),
              const SizedBox(width: 8),
              Flexible(child: Text(body)),
            ],
          ),
        if (thumbnail != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Image.memory(
              thumbnail!,
              height: 120,
              width: 180,
              cacheWidth: 360,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Icon(Icons.photo_outlined),
            ),
          ),
        if (type == 'm.audio' && waveform is List)
          WaveformView(levels: waveform.whereType<int>().toList()),
        if (caption is String && caption.isNotEmpty && caption != body)
          Text(caption),
      ],
    );
  }
}
