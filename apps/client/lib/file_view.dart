import 'app_motion.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:video_player/video_player.dart';
import 'chunked_file.dart';
import 'file_io.dart';
import 'picked_file.dart';
import 'link_platform.dart';

class FileView extends StatefulWidget {
  final mx.Event event;
  final double volume;
  const FileView({super.key, required this.event, this.volume = 1});
  @override
  State<FileView> createState() => _FileViewState();
}

class _FileViewState extends State<FileView> {
  ChunkedFile? file;
  String? error;
  bool busy = false;
  bool cancelled = false;
  double progress = 0;
  @override
  void initState() {
    super.initState();
    try {
      file = ChunkedFile(widget.event.room.client, widget.event.content);
    } catch (_) {
      error = 'Некорректное вложение';
    }
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      cancelled = false;
      error = null;
      progress = 0;
    });
    try {
      await saveFile(file!, (value) {
        if (mounted) setState(() => progress = value);
      }, () => cancelled || !mounted);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = cancelled
              ? 'Сохранение отменено'
              : 'Не удалось сохранить файл. Повторите загрузку.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (file == null) return Text(error!);
    if (file!.videoNote) {
      final caption = file!.content['caption'] as String? ?? '';
      return SizedBox(
        width: 220,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MessageVideo(
              file: file!,
              inline: true,
              volume: widget.volume,
              trailingControl: IconButton(
                tooltip: busy ? 'Отменить загрузку файла' : 'Сохранить файл',
                icon: Icon(busy ? Icons.close : Icons.download),
                onPressed: busy ? () => setState(() => cancelled = true) : save,
              ),
            ),
            if (busy) LinearProgressIndicator(value: progress),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (caption.isNotEmpty) SelectableText(caption),
          ],
        ),
      );
    }
    final video = file!.mime.startsWith('video/');
    final foreground = Theme.of(context).colorScheme.onSurface;
    return DefaultTextStyle.merge(
      style: TextStyle(color: foreground),
      child: IconTheme(
        data: IconThemeData(color: foreground),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondaryContainer,
            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.outline.withValues(alpha: .6),
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    video
                        ? Icons.movie_outlined
                        : Icons.insert_drive_file_outlined,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      file!.name,
                      textAlign: TextAlign.start,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (video)
                    IconButton(
                      tooltip: 'Смотреть видео',
                      color: foreground,
                      icon: const Icon(Icons.play_circle_outline),
                      onPressed: () => showAppDialog<void>(
                        context: context,
                        animationStyle: appAnimationStyle(context),
                        builder: (_) =>
                            MessageVideo(file: file!, volume: widget.volume),
                      ),
                    ),
                  IconButton(
                    color: foreground,
                    tooltip: busy
                        ? 'Отменить загрузку файла'
                        : 'Сохранить файл',
                    icon: Icon(busy ? Icons.close : Icons.download),
                    onPressed: busy
                        ? () => setState(() => cancelled = true)
                        : save,
                  ),
                ],
              ),
              Text(
                '${(file!.size / 1048576).toStringAsFixed(1)} МБ · ${file!.mime}',
                textAlign: TextAlign.start,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: foreground.withValues(alpha: .8),
                ),
              ),
              if (busy) LinearProgressIndicator(value: progress),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if ((file!.content['caption'] as String? ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SelectableText(
                    file!.content['caption'] as String,
                    semanticsLabel: file!.content['caption'] as String,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    cancelled = true;
    file?.clear();
    super.dispose();
  }
}

class MessageVideo extends StatefulWidget {
  final ChunkedFile? file;
  final PickedFile? draft;
  final Uri? remote;
  final bool inline;
  final bool thumbnail;
  final bool draftVideoNote;
  final double volume;
  final Widget? trailingControl;
  const MessageVideo({
    super.key,
    required this.file,
    this.inline = false,
    this.volume = 1,
    this.trailingControl,
  }) : draft = null,
       remote = null,
       thumbnail = false,
       draftVideoNote = false;
  const MessageVideo.draft({
    super.key,
    required PickedFile file,
    required bool videoNote,
    this.thumbnail = true,
    this.volume = 1,
  }) : file = null,
       draft = file,
       remote = null,
       inline = false,
       draftVideoNote = videoNote,
       trailingControl = null;
  const MessageVideo.remote({super.key, required Uri url, this.volume = 1})
    : file = null,
      draft = null,
      remote = url,
      inline = false,
      thumbnail = false,
      draftVideoNote = false,
      trailingControl = null;
  bool get videoNote => file?.videoNote ?? draftVideoNote;
  @override
  State<MessageVideo> createState() => _MessageVideoState();
}

class _MessageVideoState extends State<MessageVideo> {
  VideoPlayerController? player;
  Future<void> Function()? closeSource;
  String? error;
  bool loading = false;
  @override
  void initState() {
    super.initState();
    load(autoplay: !widget.inline && !widget.thumbnail);
  }

  Future<void> load({bool autoplay = true}) async {
    if (loading || player != null) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (widget.remote != null &&
          (!['https', 'http'].contains(widget.remote!.scheme) ||
              widget.remote!.host.isEmpty ||
              widget.remote!.userInfo.isNotEmpty)) {
        throw const FormatException('Invalid video URL');
      }
      final source = widget.remote != null
          ? (url: widget.remote.toString(), close: () async {})
          : widget.draft == null
          ? await videoSource(widget.file!)
          : await draftVideoSource(widget.draft!);
      if (!mounted) {
        await source.close();
        return;
      }
      closeSource = source.close;
      final next = VideoPlayerController.networkUrl(Uri.parse(source.url));
      player = next;
      await next.initialize();
      if (!mounted) return;
      await next.setVolume(widget.volume);
      next.addListener(refresh);
      if (autoplay) {
        await next.play();
      } else {
        // Seeking decodes a still frame without autoplay or microphone access.
        await next.seekTo(
          Duration(
            milliseconds: next.value.duration.inMilliseconds.clamp(0, 100),
          ),
        );
      }
      if (mounted) loading = false;
      refresh();
    } catch (_) {
      await player?.dispose();
      player = null;
      await closeSource?.call();
      closeSource = null;
      if (mounted) {
        setState(() {
          loading = false;
          error =
              'Видео не удалось открыть. Повторите воспроизведение или сохраните файл.';
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant MessageVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.volume != oldWidget.volume) player?.setVolume(widget.volume);
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final value = player?.value;
    final ready = value?.isInitialized == true;
    if (widget.thumbnail) {
      final duration = value?.duration.inSeconds ?? 0;
      return Semantics(
        label:
            'Предпросмотр видео · ${duration ~/ 60}:${(duration % 60).toString().padLeft(2, '0')}',
        button: true,
        child: InkWell(
          onTap: () => showAppDialog<void>(
            context: context,
            animationStyle: appAnimationStyle(context),
            builder: (_) => MessageVideo.draft(
              file: widget.draft!,
              videoNote: widget.videoNote,
              thumbnail: false,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.videoNote ? 40 : 10),
            child: SizedBox(
              width: widget.videoNote ? 56 : 72,
              height: 56,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (ready)
                    FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: value!.size.width,
                        height: value.size.height,
                        child: VideoPlayer(player!),
                      ),
                    )
                  else
                    ColoredBox(
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      child: Icon(
                        error == null
                            ? Icons.movie_outlined
                            : Icons.error_outline,
                      ),
                    ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: ColoredBox(
                      color: Colors.black54,
                      child: Text(
                        '${duration ~/ 60}:${(duration % 60).toString().padLeft(2, '0')}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final fraction = ready && value!.duration.inMilliseconds > 0
        ? value.position.inMilliseconds / value.duration.inMilliseconds
        : 0.0;
    final content = SizedBox(
      width: widget.inline ? 220 : 800,
      height: widget.inline ? 268 : 620,
      child: Column(
        children: [
          if (!widget.inline)
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Закрыть видео',
                color: Colors.white,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
          Expanded(
            child: error != null
                ? Center(
                    child: Semantics(
                      container: true,
                      liveRegion: true,
                      child: Text(
                        error!,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  )
                : widget.videoNote
                ? AspectRatio(
                    aspectRatio: 1,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipOval(
                          child: ColoredBox(
                            color: Colors.black,
                            child: ready
                                ? FittedBox(
                                    fit: BoxFit.cover,
                                    child: SizedBox(
                                      width: value!.size.width,
                                      height: value.size.height,
                                      child: VideoPlayer(player!),
                                    ),
                                  )
                                : const Icon(
                                    Icons.video_camera_front,
                                    color: Colors.white54,
                                    size: 64,
                                  ),
                          ),
                        ),
                        if (ready)
                          CircularProgressIndicator(
                            value: fraction,
                            strokeWidth: 4,
                          ),
                        if (loading && !ready)
                          const Center(child: CircularProgressIndicator()),
                      ],
                    ),
                  )
                : ready
                ? AspectRatio(
                    aspectRatio: value!.aspectRatio,
                    child: VideoPlayer(player!),
                  )
                : const Center(child: CircularProgressIndicator()),
          ),
          if (ready && !widget.videoNote)
            VideoProgressIndicator(
              player!,
              allowScrubbing: true,
              padding: const EdgeInsets.all(12),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: value?.isPlaying == true
                    ? 'Пауза видео'
                    : 'Воспроизвести видео',
                color: widget.inline && widget.videoNote
                    ? IconTheme.of(context).color
                    : Colors.white,
                onPressed: loading && !ready
                    ? null
                    : () => !ready
                          ? load()
                          : value!.isPlaying
                          ? player!.pause()
                          : player!.play(),
                icon: Icon(
                  value?.isPlaying == true
                      ? Icons.pause
                      : Icons.play_circle_outline,
                ),
              ),
              if (widget.trailingControl != null) widget.trailingControl!,
            ],
          ),
          if (widget.remote != null)
            TextButton(
              onPressed: () async {
                try {
                  await openLink(widget.remote!);
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Не удалось открыть браузер.'),
                      ),
                    );
                  }
                }
              },
              child: const Text('Открыть оригинал'),
            ),
        ],
      ),
    );
    return widget.inline
        ? widget.videoNote
              ? Center(child: content)
              : ColoredBox(color: Colors.black, child: content)
        : Dialog(backgroundColor: Colors.black, child: content);
  }

  @override
  void dispose() {
    player?.removeListener(refresh);
    player?.dispose();
    closeSource?.call();
    super.dispose();
  }
}

Future<void> showFileInfo(BuildContext context, mx.Event event) async {
  final file = ChunkedFile(event.room.client, event.content);
  try {
    await showAppDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Информация'),
        content: SelectableText(
          '${file.name}\n${file.size} байт\n${file.mime}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  } finally {
    file.clear();
  }
}
