import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:video_player/video_player.dart';
import 'chunked_file.dart';
import 'file_io.dart';

class FileView extends StatefulWidget {
  final mx.Event event;
  const FileView({super.key, required this.event});
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
    final video = file!.mime.startsWith('video/');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(file!.videoNote ? 32 : 16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (file!.videoNote)
            SizedBox(
              width: 240,
              height: 280,
              child: MessageVideo(file: file!, inline: true),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                file!.videoNote
                    ? Icons.video_camera_front
                    : video
                    ? Icons.movie_outlined
                    : Icons.insert_drive_file_outlined,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  file!.videoNote ? 'Видеокружок' : file!.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (video && !file!.videoNote)
                IconButton(
                  tooltip: 'Смотреть видео',
                  icon: const Icon(Icons.play_circle_outline),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => MessageVideo(file: file!),
                  ),
                ),
              IconButton(
                tooltip: busy ? 'Отменить загрузку файла' : 'Сохранить файл',
                icon: Icon(busy ? Icons.close : Icons.download),
                onPressed: busy ? () => setState(() => cancelled = true) : save,
              ),
            ],
          ),
          Text(
            '${(file!.size / 1048576).toStringAsFixed(1)} МБ · ${file!.mime}',
            style: Theme.of(context).textTheme.labelSmall,
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
              child: SelectableText(file!.content['caption'] as String),
            ),
        ],
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
  final ChunkedFile file;
  final bool inline;
  const MessageVideo({super.key, required this.file, this.inline = false});
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
    if (!widget.inline) load();
  }

  Future<void> load() async {
    if (loading || player != null) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final source = await videoSource(widget.file);
      if (!mounted) {
        await source.close();
        return;
      }
      closeSource = source.close;
      final next = VideoPlayerController.networkUrl(Uri.parse(source.url));
      player = next;
      await next.initialize();
      if (!mounted) return;
      next.addListener(refresh);
      await next.play();
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

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final value = player?.value;
    final ready = value?.isInitialized == true;
    final fraction = ready && value!.duration.inMilliseconds > 0
        ? value.position.inMilliseconds / value.duration.inMilliseconds
        : 0.0;
    final content = SizedBox(
      width: widget.inline ? 240 : 800,
      height: widget.inline ? 280 : 620,
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
                    child: Text(
                      error!,
                      style: const TextStyle(color: Colors.white),
                    ),
                  )
                : widget.file.videoNote
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
          if (ready && !widget.file.videoNote)
            VideoProgressIndicator(
              player!,
              allowScrubbing: true,
              padding: const EdgeInsets.all(12),
            ),
          IconButton(
            tooltip: value?.isPlaying == true
                ? 'Пауза видео'
                : 'Воспроизвести видео',
            color: Colors.white,
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
        ],
      ),
    );
    return widget.inline
        ? ColoredBox(color: Colors.black, child: content)
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
