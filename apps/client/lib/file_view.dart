import 'temporary_message.dart' show messageExpiry;
import 'video_poster.dart';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:video_player/video_player.dart';
import 'app_motion.dart';
import 'chunked_file.dart';
import 'file_io.dart';
import 'picked_file.dart';
import 'link_platform.dart';
import 'message_media_cache.dart';
import 'message_playback.dart';
import 'smooth_progress_ring.dart';

class FileView extends StatefulWidget {
  final mx.Event event;
  final mx.Event? originalEvent;
  final double volume;
  const FileView({
    super.key,
    required this.event,
    this.originalEvent,
    this.volume = 1,
  });
  @override
  State<FileView> createState() => _FileViewState();
}

class _FileViewState extends State<FileView> {
  ChunkedFile? file;
  @override
  void initState() {
    super.initState();
    try {
      file = ChunkedFile(widget.event.room.client, widget.event.content);
    } catch (_) {
      /* Render a bounded error below. */
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = this.file;
    if (file == null) return const Text('Некорректное вложение');
    final caption = file.content['caption'] as String? ?? '';
    if (file.videoNote) {
      return SizedBox(
        width: 220,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MessageVideo(
              file: file,
              inline: true,
              volume: widget.volume,
              previewKey: '${widget.event.room.id}/${widget.event.eventId}',
              previewExpiresAt: messageExpiry(
                widget.originalEvent ?? widget.event,
              ),
            ),
            if (caption.isNotEmpty) SelectableText(caption),
          ],
        ),
      );
    }
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
                children: [
                  Icon(
                    file.mime.startsWith('video/')
                        ? Icons.movie_outlined
                        : Icons.insert_drive_file_outlined,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      file.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (file.mime.startsWith('video/'))
                    IconButton(
                      tooltip: 'Смотреть видео',
                      icon: const Icon(Icons.play_circle_outline),
                      onPressed: () => showAppDialog<void>(
                        context: context,
                        builder: (_) =>
                            MessageVideo(file: file, volume: widget.volume),
                      ),
                    ),
                  SaveMessageFile(event: widget.event),
                ],
              ),
              Text(
                '${(file.size / 1048576).toStringAsFixed(1)} МБ · ${file.mime}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: foreground.withValues(alpha: .8),
                ),
              ),
              if (caption.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SelectableText(caption),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    if ((widget.originalEvent ?? widget.event).redacted) {
      MessageMediaCache.of(
        widget.event.room.client,
      ).removeFrame('${widget.event.room.id}/${widget.event.eventId}');
    }
    file?.clear();
    super.dispose();
  }
}

/// Save owns its manifest, so closing a video view cannot interrupt its range reads.
class SaveMessageFile extends StatefulWidget {
  final mx.Event event;
  final bool compact;
  final Color? color;
  const SaveMessageFile({
    super.key,
    required this.event,
    this.compact = false,
    this.color,
  });
  @override
  State<SaveMessageFile> createState() => _SaveMessageFileState();
}

class _SaveMessageFileState extends State<SaveMessageFile> {
  bool busy = false, cancelled = false;
  double progress = 0;
  Future<void> save() async {
    if (busy) {
      setState(() => cancelled = true);
      return;
    }
    setState(() {
      busy = true;
      cancelled = false;
      progress = 0;
    });
    ChunkedFile? file;
    try {
      file = ChunkedFile(widget.event.room.client, widget.event.content);
      await saveFile(file, (value) {
        if (mounted) setState(() => progress = value);
      }, () => cancelled || !mounted);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              cancelled
                  ? 'Сохранение отменено'
                  : 'Не удалось сохранить файл. Повторите загрузку.',
            ),
          ),
        );
      }
    } finally {
      file?.clear();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.compact ? 24 : 48,
    child: IconButton(
      tooltip: busy ? 'Отменить загрузку файла' : 'Сохранить файл',
      onPressed: save,
      color: widget.color,
      style: widget.compact
          ? IconButton.styleFrom(
              minimumSize: const Size(24, 24),
              maximumSize: const Size(24, 24),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )
          : null,
      icon: busy
          ? SizedBox.square(
              dimension: widget.compact ? 12 : 20,
              child: CircularProgressIndicator(value: progress, strokeWidth: 2),
            )
          : Icon(Icons.download, size: widget.compact ? 10 : 24),
    ),
  );
  @override
  void dispose() {
    cancelled = true;
    super.dispose();
  }
}

class MessageVideo extends StatefulWidget {
  final ChunkedFile? file;
  final PickedFile? draft;
  final Uri? remote;
  final bool inline, thumbnail, draftVideoNote;
  final double volume;
  final String? previewKey;
  final DateTime? previewExpiresAt;
  const MessageVideo({
    super.key,
    required this.file,
    this.inline = false,
    this.volume = 1,
    this.previewKey,
    this.previewExpiresAt,
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
       previewKey = null,
       previewExpiresAt = null;
  const MessageVideo.remote({super.key, required Uri url, this.volume = 1})
    : file = null,
      draft = null,
      remote = url,
      inline = false,
      thumbnail = false,
      draftVideoNote = false,
      previewKey = null,
      previewExpiresAt = null;
  bool get videoNote => file?.videoNote ?? draftVideoNote;
  @override
  State<MessageVideo> createState() => _MessageVideoState();
}

class _MessageVideoState extends State<MessageVideo> {
  VideoPlayerController? player;
  Future<void> Function()? closeSource;
  final frameKey = GlobalKey();
  ui.Image? poster;
  Timer? snapshotTimer;
  bool loading = false;
  String? error;
  MessageMediaCache? get cache =>
      widget.previewKey == null || widget.file == null
      ? null
      : MessageMediaCache.of(widget.file!.client);
  @override
  void initState() {
    super.initState();
    poster = cache?.frame(widget.previewKey!);
    // A cached still is immediately visible and needs no decoder/range request.
    if (poster == null) {
      unawaited(load(autoplay: !widget.inline && !widget.thumbnail));
    }
  }

  Future<void> load({bool autoplay = true}) async {
    if (loading || player != null) return;
    final request = autoplay ? messagePlayback.request(this) : null;
    setState(() {
      loading = true;
      error = null;
    });
    VideoPlayerController? next;
    try {
      if (widget.remote != null &&
          (!['https', 'http'].contains(widget.remote!.scheme) ||
              widget.remote!.host.isEmpty ||
              widget.remote!.userInfo.isNotEmpty)) {
        throw const FormatException('Invalid video URL');
      }
      final source = widget.remote != null
          ? (url: widget.remote.toString(), close: () async {})
          : widget.draft != null
          ? await draftVideoSource(widget.draft!)
          : await videoSource(widget.file!);
      if (!mounted) {
        await source.close();
        return;
      }
      closeSource = source.close;
      next = VideoPlayerController.networkUrl(Uri.parse(source.url));
      player = next;
      await next.initialize();
      if (!mounted) return;
      await next.setVolume(widget.volume);
      next.addListener(refresh);
      if (autoplay) {
        await messagePlayback.start(this, request!, next.play, next.pause);
      } else {
        await next.seekTo(
          Duration(
            milliseconds: next.value.duration.inMilliseconds.clamp(0, 100),
          ),
        );
      }
      if (!mounted) return;
      setState(() => loading = false);
      schedulePoster();
    } catch (_) {
      next?.removeListener(refresh);
      if (!mounted) return; // dispose owns the decoder and range source now.
      await messagePlayback.pause(this);
      await next?.dispose();
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

  void schedulePoster() {
    if (poster != null ||
        cache == null ||
        snapshotTimer != null ||
        player?.value.isInitialized != true ||
        player!.value.isPlaying) {
      return;
    }
    snapshotTimer = Timer(const Duration(milliseconds: 180), () async {
      snapshotTimer = null;
      try {
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || player?.value.isPlaying != false) return;
        final boundary = frameKey.currentContext?.findRenderObject();
        if (boundary is! RenderRepaintBoundary || boundary.debugNeedsPaint) {
          return;
        }
        final image = await videoPoster(boundary, player!.dataSource);
        if (!mounted) {
          image.dispose();
          return;
        }
        cache?.saveFrame(
          widget.previewKey!,
          image,
          expiresAt: widget.previewExpiresAt,
        );
        setState(() => poster = image);
      } catch (_) {
        /* Keeping playback available is more important than a missing still. */
      }
    });
  }

  void refresh() {
    if (!mounted) return;
    setState(() {});
    schedulePoster();
  }

  Future<void> toggle() async {
    if (loading) return;
    final player = this.player;
    if (player?.value.isInitialized != true) {
      await load();
      return;
    }
    try {
      if (player!.value.isPlaying) {
        await messagePlayback.pause(this);
      } else {
        final request = messagePlayback.request(this);
        if (player.value.position >= player.value.duration) {
          await player.seekTo(Duration.zero);
        }
        if (mounted) {
          await messagePlayback.start(this, request, player.play, player.pause);
        }
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Не удалось воспроизвести видео. Повторите попытку.',
        );
      }
    }
  }

  @override
  void didUpdateWidget(MessageVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.volume != oldWidget.volume) {
      unawaited(player?.setVolume(widget.volume));
    }
  }

  Widget surface() {
    final value = player?.value;
    if (value?.isInitialized != true) {
      return poster != null
          ? RawImage(image: poster, fit: BoxFit.cover)
          : const ColoredBox(
              color: Colors.black,
              child: Icon(
                Icons.video_camera_front,
                color: Colors.white54,
                size: 64,
              ),
            );
    }
    return RepaintBoundary(
      key: frameKey,
      child: FittedBox(
        fit: widget.videoNote ? BoxFit.cover : BoxFit.contain,
        child: SizedBox(
          width: value!.size.width,
          height: value.size.height,
          child: VideoPlayer(player!),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final value = player?.value;
    final ready = value?.isInitialized == true;
    final playing = value?.isPlaying == true;
    if (widget.thumbnail) {
      final seconds = value?.duration.inSeconds ?? 0;
      return Semantics(
        label:
            'Предпросмотр видео · ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
        button: true,
        child: InkWell(
          onTap: () => showAppDialog<void>(
            context: context,
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
                  surface(),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: ColoredBox(
                      color: Colors.black54,
                      child: Text(
                        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
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
    final visual = widget.videoNote
        ? AspectRatio(
            aspectRatio: 1,
            child: ClipOval(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipOval(child: surface()),
                  IgnorePointer(
                    child: SmoothProgressRing(
                      value: fraction,
                      running: playing,
                      duration: value?.duration ?? Duration.zero,
                      speed: value?.playbackSpeed ?? 1,
                    ),
                  ),
                  Positioned.fill(
                    child: Semantics(
                      button: true,
                      label: playing ? 'Пауза видео' : 'Воспроизвести видео',
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: toggle,
                      ),
                    ),
                  ),
                  if (!playing && !loading)
                    Center(
                      child: IconButton(
                        tooltip: 'Воспроизвести видео',
                        iconSize: 48,
                        color: Colors.white,
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black38,
                        ),
                        onPressed: toggle,
                        icon: const Icon(Icons.play_arrow_rounded),
                      ),
                    ),
                  if (loading)
                    const IgnorePointer(
                      child: Center(child: CircularProgressIndicator()),
                    ),
                ],
              ),
            ),
          )
        : surface();
    final content = SizedBox(
      width: widget.inline ? 220 : 800,
      height: widget.inline ? 220 : 620,
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
          Expanded(child: Center(child: visual)),
          if (error != null)
            Text(
              error!,
              style: TextStyle(
                color: widget.inline
                    ? Theme.of(context).colorScheme.error
                    : Colors.white,
              ),
            ),
          if (ready && !widget.videoNote)
            VideoProgressIndicator(
              player!,
              allowScrubbing: true,
              padding: const EdgeInsets.all(12),
            ),
          if (!widget.videoNote)
            IconButton(
              tooltip: playing ? 'Пауза видео' : 'Воспроизвести видео',
              color: Colors.white,
              onPressed: loading ? null : toggle,
              icon: Icon(playing ? Icons.pause : Icons.play_circle_outline),
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
        ? content
        : Dialog(backgroundColor: Colors.transparent, child: content);
  }

  @override
  void dispose() {
    snapshotTimer?.cancel();
    final player = this.player;
    player?.removeListener(refresh);
    final close = closeSource;
    unawaited(
      messagePlayback
          .pause(this)
          .whenComplete(() async {
            await player?.dispose();
            messagePlayback.closed(this);
            await close?.call();
          })
          .catchError((Object _) {}),
    );
    final poster = this.poster;
    if (poster != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => poster.dispose());
    }
    super.dispose();
  }
}

Future<void> showFileInfo(BuildContext context, mx.Event event) async {
  ChunkedFile? file;
  String information;
  if (event.messageType == mx.MessageTypes.Audio) {
    final info = event.infoMap;
    final duration = info['duration'];
    information = [
      event.body,
      if (info['size'] case final num size when size.isFinite && size >= 0)
        '${size.toInt()} байт',
      if (info['mimetype'] case final String mime) mime,
      if (duration is num && duration.isFinite && duration >= 0)
        'Длительность: ${(duration / 1000).toStringAsFixed(1)} с',
    ].join('\n');
  } else {
    file = ChunkedFile(event.room.client, event.content);
    information = '${file.name}\n${file.size} байт\n${file.mime}';
  }
  try {
    await showAppDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Информация'),
        content: SingleChildScrollView(child: SelectableText(information)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  } finally {
    file?.clear();
  }
}
