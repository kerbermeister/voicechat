import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'link_platform.dart';
import 'link_preview.dart';
import 'file_view.dart';
import 'embedded_video.dart';

Future<void> followLink(BuildContext context, Uri url) async {
  try {
    await openLink(url);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Не удалось открыть браузер. Ссылку можно скопировать из сообщения.',
          ),
        ),
      );
    }
  }
}

class LinkedText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const LinkedText({super.key, required this.text, required this.style});
  @override
  State<LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends State<LinkedText> {
  final taps = <Uri, TapGestureRecognizer>{};
  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    var start = 0;
    for (final url in messageLinks(widget.text)) {
      final index = widget.text.indexOf(url.toString(), start);
      if (index < start) continue;
      spans.add(TextSpan(text: widget.text.substring(start, index)));
      final tap = taps.putIfAbsent(
        url,
        () => TapGestureRecognizer()..onTap = () => followLink(context, url),
      );
      spans.add(
        TextSpan(
          text: url.toString(),
          recognizer: tap,
          style: const TextStyle(decoration: TextDecoration.underline),
        ),
      );
      start = index + url.toString().length;
    }
    spans.add(TextSpan(text: widget.text.substring(start)));
    return SelectableText.rich(
      TextSpan(children: spans),
      style: widget.style,
      semanticsLabel: widget.text,
    );
  }

  @override
  void didUpdateWidget(LinkedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      for (final tap in taps.values) {
        tap.dispose();
      }
      taps.clear();
    }
  }

  @override
  void dispose() {
    for (final tap in taps.values) {
      tap.dispose();
    }
    super.dispose();
  }
}

class LinkCards extends StatelessWidget {
  final String text;
  final dynamic previews;
  const LinkCards({super.key, required this.text, this.previews});
  @override
  Widget build(BuildContext context) {
    final metadata = messagePreviews(text, previews);
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final url in messageLinks(text))
          Builder(
            builder: (_) {
              final preview = metadata.where((p) => p.url == url).firstOrNull;
              final video = RegExp(
                r'\.(mp4|webm)$',
                caseSensitive: false,
              ).hasMatch(url.path);
              final youtube = youtubeVideoId(url);
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Material(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (preview?.image != null)
                        Image.memory(
                          preview!.image!,
                          height: 150,
                          width: 360,
                          fit: BoxFit.cover,
                          cacheWidth: 720,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ListTile(
                        dense: true,
                        title: Text(
                          preview?.title.isNotEmpty == true
                              ? preview!.title
                              : url.host,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          [
                            url.host,
                            if (preview?.description.isNotEmpty == true)
                              preview!.description,
                          ].join('\n'),
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                        trailing: Icon(
                          Icons.open_in_new,
                          size: 18,
                          color: colors.primary,
                        ),
                        onTap: () => followLink(context, url),
                      ),
                      if (video || youtube != null)
                        TextButton.icon(
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => youtube == null
                                ? MessageVideo.remote(url: url)
                                : Dialog(
                                    child: SizedBox(
                                      width: 800,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Align(
                                            alignment: Alignment.centerRight,
                                            child: IconButton(
                                              tooltip: 'Закрыть видео',
                                              onPressed: () =>
                                                  Navigator.pop(context),
                                              icon: const Icon(Icons.close),
                                            ),
                                          ),
                                          SizedBox(
                                            height:
                                                (MediaQuery.sizeOf(
                                                          context,
                                                        ).width *
                                                        .56)
                                                    .clamp(200, 450),
                                            child: EmbeddedVideo(id: youtube),
                                          ),
                                          TextButton(
                                            onPressed: () =>
                                                followLink(context, url),
                                            child: const Text(
                                              'Если видео недоступно — открыть оригинал',
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                          ),
                          icon: const Icon(Icons.play_circle_outline),
                          label: const Text('Смотреть видео'),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
