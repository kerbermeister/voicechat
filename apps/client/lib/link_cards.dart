import 'app_motion.dart';
import 'emoji_style.dart';
import 'message_format.dart';
import 'package:markdown/markdown.dart' as md;
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
  final bool selectable;
  final TextStyle style;
  const LinkedText({
    super.key,
    required this.text,
    required this.style,
    this.selectable = true,
  });
  @override
  State<LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends State<LinkedText> {
  final taps = <Uri, TapGestureRecognizer>{};
  @override
  Widget build(BuildContext context) {
    List<InlineSpan> plain(String text) {
      final parts = text.split('❤️');
      return [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0) const TextSpan(text: '❤️', style: emojiStyle),
          TextSpan(text: parts[i]),
        ],
      ];
    }

    List<InlineSpan> linked(String text, {bool struck = false}) {
      final spans = <InlineSpan>[];
      var start = 0;
      for (final url in messageLinks(text)) {
        final index = text.indexOf(url.toString(), start);
        if (index < start) continue;
        spans.addAll(plain(text.substring(start, index)));
        final tap = taps.putIfAbsent(
          url,
          () => TapGestureRecognizer()..onTap = () => followLink(context, url),
        );
        spans.add(
          TextSpan(
            text: url.toString(),
            recognizer: tap,
            style: TextStyle(
              decoration: TextDecoration.combine([
                TextDecoration.underline,
                if (struck) TextDecoration.lineThrough,
              ]),
            ),
          ),
        );
        start = index + url.toString().length;
      }
      spans.addAll(plain(text.substring(start)));
      return spans;
    }

    InlineSpan render(md.Node node, {bool struck = false}) => node is md.Element
        ? TextSpan(
            style: node.tag == 'del'
                ? const TextStyle(decoration: TextDecoration.lineThrough)
                : null,
            children: node.children
                ?.map(
                  (child) => render(child, struck: struck || node.tag == 'del'),
                )
                .toList(),
          )
        : TextSpan(children: linked(node.textContent, struck: struck));
    final nodes = parseMessageFormat(widget.text);
    final spans = nodes.map((node) => render(node)).toList();
    final spoken = nodes.map((node) => node.textContent).join();
    if (!widget.selectable) {
      return Text.rich(
        TextSpan(children: spans),
        style: widget.style,
        semanticsLabel: spoken,
      );
    }
    return SelectableText.rich(
      TextSpan(children: spans),
      style: widget.style,
      semanticsLabel: spoken,
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

class LinkCards extends StatefulWidget {
  final String text;
  final dynamic previews;
  const LinkCards({super.key, required this.text, this.previews});
  @override
  State<LinkCards> createState() => _LinkCardsState();
}

class _LinkCardsState extends State<LinkCards> {
  late List<LinkPreview> metadata;
  @override
  void initState() {
    super.initState();
    metadata = messagePreviews(widget.text, widget.previews);
  }

  @override
  void didUpdateWidget(LinkCards oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.previews != widget.previews) {
      metadata = messagePreviews(widget.text, widget.previews);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final url in messageLinks(widget.text))
          Builder(
            builder: (_) {
              final preview = metadata.where((p) => p.url == url).firstOrNull;
              final video = RegExp(
                r'\.(mp4|webm)$',
                caseSensitive: false,
              ).hasMatch(url.path);
              final youtube = youtubeVideoId(url);
              void open() {
                if (!video && youtube == null) {
                  followLink(context, url);
                  return;
                }
                showAppDialog<void>(
                  context: context,
                  builder: (dialogContext) => youtube == null
                      ? MessageVideo.remote(url: url)
                      : Dialog(
                          child: SizedBox(
                            width: 800,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    8,
                                    12,
                                    0,
                                  ),
                                  child: AppDialogTitle(
                                    child: Text(
                                      preview?.title ?? 'Видео',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  height:
                                      (MediaQuery.sizeOf(context).width * .56)
                                          .clamp(160, 450),
                                  child: EmbeddedVideo(id: youtube),
                                ),
                                TextButton(
                                  onPressed: () => followLink(context, url),
                                  child: const Text(
                                    'Если видео недоступно — открыть оригинал',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                );
              }

              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Material(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: open,
                    child: SizedBox(
                      width: 400,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (preview?.image != null)
                            AspectRatio(
                              aspectRatio: 16 / 9,
                              child: Image.memory(
                                preview!.image!,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                                cacheWidth: 720,
                                errorBuilder: (_, _, _) =>
                                    const Icon(Icons.link),
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
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
                                const SizedBox(height: 3),
                                Text(
                                  url.host,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: colors.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
