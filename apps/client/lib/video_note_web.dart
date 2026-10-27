import 'smooth_progress_ring.dart';
import 'dart:async';
import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;
import 'active_capture.dart';
import 'file_source_web.dart' show fileSource;
import 'video_note.dart' show VideoNoteResult;

Future<VideoNoteResult?> recordWebVideoNote(
  BuildContext context,
  int maxSeconds, {
  ValueNotifier<bool>? held,
  ValueNotifier<bool>? cancelled,
  void Function(bool)? onRecording,
}) {
  final done = Completer<VideoNoteResult?>();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _WebNote(
      maxSeconds: maxSeconds,
      held: held,
      cancelled: cancelled,
      onRecording: onRecording,
      complete: (result) {
        if (done.isCompleted) return;
        entry.remove();
        entry.dispose();
        done.complete(result);
      },
    ),
  );
  FocusScope.of(context).unfocus();
  Overlay.of(context).insert(entry);
  return done.future;
}

class _WebNote extends StatefulWidget {
  final int maxSeconds;
  final ValueNotifier<bool>? held, cancelled;
  final void Function(bool)? onRecording;
  final void Function(VideoNoteResult?) complete;
  const _WebNote({
    required this.maxSeconds,
    this.held,
    this.cancelled,
    this.onRecording,
    required this.complete,
  });
  @override
  State<_WebNote> createState() => _WebNoteState();
}

class _WebNoteState extends State<_WebNote> with WidgetsBindingObserver {
  final video = web.HTMLVideoElement()
    ..muted = true
    ..autoplay = true
    ..playsInline = true;
  final canvas = web.HTMLCanvasElement()
    ..width = 480
    ..height = 480;
  web.MediaStream? capture, output;
  web.MediaRecorder? recorder;
  final chunks = <web.Blob>[];
  final clock = Stopwatch();
  Timer? frames;
  bool rear = false, switching = false, finishing = false, closed = false;
  String? error;
  late final Future<void> opening;
  late final Future<void> Function() interruptCapture = interrupt;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.held?.addListener(release);
    registerCapture(interruptCapture);
    opening = start();
  }

  Future<web.MediaStream> openCamera(bool rear, {required bool audio}) => web
      .window
      .navigator
      .mediaDevices
      .getUserMedia(
        {
              'audio': audio,
              'video': {
                'facingMode': {
                  rear ? 'exact' : 'ideal': rear ? 'environment' : 'user',
                },
                'width': {'ideal': 480},
                'height': {'ideal': 480},
                'frameRate': {'ideal': 30},
              },
            }.jsify()
            as web.MediaStreamConstraints,
      )
      .toDart;

  void stopTracks(web.MediaStream? stream) {
    for (final track
        in stream?.getTracks().toDart ?? <web.MediaStreamTrack>[]) {
      track.stop();
    }
  }

  Future<void> start() async {
    try {
      final stream = await openCamera(false, audio: true);
      if (closed) {
        stopTracks(stream);
        return;
      }
      capture = stream;
      if (widget.held?.value == false) {
        finish(discard: true);
        return;
      }
      video.srcObject = stream;
      await video.play().toDart;
      if (closed) return;
      // A stable canvas track lets cameras change without changing recorder tracks.
      output = canvas.captureStream(30);
      for (final audio in stream.getAudioTracks().toDart) {
        output!.addTrack(audio);
      }
      final mime = [
        'video/mp4',
        'video/webm;codecs=vp8,opus',
        'video/webm',
      ].firstWhere((mime) => web.MediaRecorder.isTypeSupported(mime));
      final next = web.MediaRecorder(
        output!,
        web.MediaRecorderOptions(mimeType: mime),
      );
      recorder = next;
      next.ondataavailable = ((web.BlobEvent event) {
        if (event.data.size > 0) chunks.add(event.data);
      }).toJS;
      next.onstop = ((web.Event _) => completeRecording()).toJS;
      next.onerror = ((web.Event _) {
        if (!closed) {
          setState(() => error = 'Запись прервана. Повторите запись.');
        }
        finish(discard: true);
      }).toJS;
      draw();
      next.start(250);
      clock.start();
      widget.onRecording?.call(true);
      frames = Timer.periodic(const Duration(milliseconds: 33), (_) {
        if (closed) return;
        draw();
        setState(() {});
        if (clock.elapsedMilliseconds >= widget.maxSeconds * 1000) finish();
      });
      release();
    } catch (_) {
      stopTracks(capture);
      stopTracks(output);
      if (closed) return;
      if (widget.held?.value == false) {
        widget.complete(null);
        return;
      }
      setState(
        () => error =
            'Не удалось начать запись. Проверьте доступ к камере и микрофону.',
      );
    }
  }

  void draw() {
    if (video.videoWidth == 0 || video.videoHeight == 0 || switching) return;
    final ctx = canvas.context2D;
    final side = video.videoWidth < video.videoHeight
        ? video.videoWidth
        : video.videoHeight;
    ctx.save();
    if (!rear) {
      ctx.translate(480, 0);
      ctx.scale(-1, 1);
    }
    ctx.drawImage(
      video,
      (video.videoWidth - side) / 2,
      (video.videoHeight - side) / 2,
      side,
      side,
      0,
      0,
      480,
      480,
    );
    ctx.restore();
  }

  Future<void> switchCamera() async {
    if (switching || finishing || capture == null) return;
    setState(() => switching = true);
    final previous = rear;
    for (final track in capture!.getVideoTracks().toDart) {
      track.stop();
      capture!.removeTrack(track);
    }
    Future<void> replace(bool direction) async {
      final next = await openCamera(direction, audio: false);
      if (closed || finishing) {
        stopTracks(next);
        return;
      }
      for (final track in next.getVideoTracks().toDart) {
        capture!.addTrack(track);
      }
      video.srcObject = capture;
      await video.play().toDart;
      rear = direction;
    }

    try {
      await replace(!previous);
    } catch (_) {
      try {
        await replace(previous);
      } catch (_) {
        finish(interrupted: true);
      }
      if (!closed) setState(() => error = 'Не удалось переключить камеру');
    } finally {
      if (!closed) setState(() => switching = false);
      release();
    }
  }

  void release() {
    if (widget.held?.value == false && !closed) {
      finish(discard: widget.cancelled?.value == true);
    }
  }

  bool discard = false, interrupted = false;
  void finish({bool discard = false, bool interrupted = false}) {
    if (finishing || closed) return;
    finishing = true;
    this.discard = discard;
    this.interrupted = interrupted;
    clock.stop();
    frames?.cancel();
    widget.onRecording?.call(false);
    final recording = recorder;
    if (recording == null) {
      stopTracks(capture);
      widget.complete(null);
    } else if (recording.state != 'inactive') {
      recording.stop();
    } else {
      completeRecording();
    }
  }

  void completeRecording() {
    if (closed) return;
    stopTracks(capture);
    stopTracks(output);
    if (discard || chunks.isEmpty) {
      widget.complete(null);
      return;
    }
    final mime = recorder!.mimeType;
    final file = web.File(
      chunks.toJS,
      'video-note-${DateTime.now().millisecondsSinceEpoch}.${mime.contains('mp4') ? 'mp4' : 'webm'}',
      web.FilePropertyBag(type: mime),
    );
    widget.complete((
      file: fileSource(file),
      duration: clock.elapsedMilliseconds.clamp(1, widget.maxSeconds * 1000),
      interrupted: interrupted,
    ));
  }

  Future<void> interrupt() async {
    finish(interrupted: true);
    await opening;
    stopTracks(capture);
    stopTracks(output);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (clock.isRunning &&
        (state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused)) {
      finish(interrupted: true);
    }
  }

  @override
  Widget build(BuildContext context) => FocusScope(
    autofocus: true,
    child: Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          finish(discard: true);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          const ModalBarrier(dismissible: false, color: Colors.black54),
          Center(
            child: Material(
              color: Colors.transparent,
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: (MediaQuery.sizeOf(context).shortestSide * .7)
                          .clamp(100, 320),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipOval(
                            child: HtmlElementView.fromTagName(
                              tagName: 'div',
                              onElementCreated: (element) {
                                final container = element as web.HTMLDivElement;
                                canvas.style.width = '100%';
                                canvas.style.height = '100%';
                                canvas.style.pointerEvents = 'none';
                                container.append(canvas);
                              },
                            ),
                          ),
                          if (!clock.isRunning && !finishing && error == null)
                            const Center(child: CircularProgressIndicator()),
                          IgnorePointer(
                            child: SmoothProgressRing(
                              value:
                                  clock.elapsedMilliseconds /
                                  (widget.maxSeconds * 1000),
                              running: clock.isRunning,
                              duration: Duration(seconds: widget.maxSeconds),
                              strokeWidth: 6,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${clock.elapsed.inSeconds} / ${widget.maxSeconds} с',
                      style: const TextStyle(color: Colors.white),
                    ),
                    Text(
                      widget.held == null
                          ? 'Нажмите отправить, когда закончите'
                          : 'Отпустите, чтобы отправить',
                      style: const TextStyle(color: Colors.white),
                    ),
                    if (error != null)
                      Text(error!, style: const TextStyle(color: Colors.white)),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton.filledTonal(
                          tooltip: 'Отменить запись',
                          onPressed: () => finish(discard: true),
                          icon: const Icon(Icons.close),
                        ),
                        IconButton.filledTonal(
                          tooltip: 'Переключить камеру',
                          onPressed: switching || !clock.isRunning
                              ? null
                              : switchCamera,
                          icon: const Icon(Icons.cameraswitch),
                        ),
                        if (widget.held == null)
                          IconButton.filled(
                            tooltip: 'Отправить',
                            onPressed: clock.isRunning ? finish : null,
                            icon: const Icon(Icons.send),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
  @override
  void dispose() {
    closed = true;
    frames?.cancel();
    clock.stop();
    widget.onRecording?.call(false);
    widget.held?.removeListener(release);
    releaseCapture(interruptCapture);
    WidgetsBinding.instance.removeObserver(this);
    if (recorder?.state == 'recording') recorder!.stop();
    stopTracks(capture);
    stopTracks(output);
    video.srcObject = null;
    super.dispose();
  }
}
