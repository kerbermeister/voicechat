import 'app_motion.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'picked_file.dart';
import 'file_io.dart';
import 'active_capture.dart';

typedef VideoNoteResult = ({PickedFile file, int duration, bool interrupted});

Future<VideoNoteResult?> recordVideoNote(
  BuildContext context,
  int maxSeconds, {
  ValueNotifier<bool>? held,
  ValueNotifier<bool>? cancelled,
  void Function(bool)? onRecording,
}) async {
  await stopActiveCapture();
  if (!context.mounted) return null;
  if (held != null) {
    // A Navigator route cancels the original pointer; an overlay preserves hold/release.
    final completed = Completer<VideoNoteResult?>();
    late final OverlayEntry overlay;
    overlay = OverlayEntry(
      builder: (_) => Stack(
        children: [
          const ModalBarrier(dismissible: false, color: Colors.black54),
          FocusScope(
            autofocus: true,
            child: _Recorder(
              maxSeconds: maxSeconds,
              held: held,
              cancelled: cancelled,
              onRecording: onRecording,
              onComplete: (result) {
                if (completed.isCompleted) return;
                overlay.remove();
                overlay.dispose();
                completed.complete(result);
              },
            ),
          ),
        ],
      ),
    );
    FocusScope.of(context).unfocus();
    Overlay.of(context).insert(overlay);
    return completed.future;
  }
  return showAppDialog<VideoNoteResult>(
    context: context,
    animationStyle: appAnimationStyle(context),
    barrierDismissible: false,
    builder: (_) =>
        _Recorder(maxSeconds: maxSeconds, held: held, onRecording: onRecording),
  );
}

class _Recorder extends StatefulWidget {
  final int maxSeconds;
  final ValueNotifier<bool>? held;
  final ValueNotifier<bool>? cancelled;
  final void Function(bool)? onRecording;
  final void Function(VideoNoteResult?)? onComplete;
  const _Recorder({
    required this.maxSeconds,
    this.held,
    this.cancelled,
    this.onRecording,
    this.onComplete,
  });
  @override
  State<_Recorder> createState() => _RecorderState();
}

class _RecorderState extends State<_Recorder> with WidgetsBindingObserver {
  List<CameraDescription> cameras = [];
  CameraController? camera;
  Future<void>? cameraDisposal;
  bool busy = false;
  bool _completed = false;
  bool _discard = false;
  String? error;
  final clock = Stopwatch();
  Timer? timer;
  int index = 0;
  late final Future<void> initializing;
  late final Future<void> Function() captureCancellation = cancelForCall;
  void complete([VideoNoteResult? result]) {
    if (!mounted || _completed) return;
    _completed = true;
    if (widget.onComplete != null) {
      widget.onComplete!(result);
    } else {
      Navigator.pop(context, result);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.held?.addListener(releaseHold);
    initializing = init();
    registerCapture(captureCancellation);
  }

  Future<void> init() async {
    if (mounted) setState(() => error = null);
    try {
      cameras = await availableCameras().timeout(const Duration(seconds: 10));
      if (!mounted) return;
      index = cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
      );
      if (index < 0) index = 0;
      await open();
      if (mounted) {
        if (widget.held?.value != false) {
          await start();
        } else {
          complete();
        }
      }
    } catch (_) {
      if (widget.held?.value == false) {
        complete();
        return;
      }
      if (mounted) {
        setState(
          () => error = 'Камера не ответила. Проверьте разрешения и повторите.',
        );
      }
    }
  }

  Future<void> open() async {
    if (cameras.isEmpty) throw StateError('No camera');
    final next = CameraController(
      cameras[index],
      ResolutionPreset.medium,
      enableAudio: true,
    );
    camera = next;
    try {
      await next.initialize().timeout(const Duration(seconds: 30));
    } catch (_) {
      if (identical(camera, next)) camera = null;
      unawaited(
        next
            .dispose()
            .timeout(const Duration(seconds: 5))
            .catchError((Object _) {}),
      );
      rethrow;
    }
    if (mounted) {
      setState(() {});
    } else {
      await next.dispose();
    }
  }

  Future<void> closeCamera() async {
    final previous = camera;
    if (previous == null) {
      await cameraDisposal;
      return;
    }
    camera = null;
    if (mounted) {
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
    }
    await (cameraDisposal = previous.dispose());
  }

  Future<void> cancelForCall() async {
    await initializing;
    while (busy && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!mounted) {
      await cameraDisposal;
      return;
    }
    if (clock.isRunning) {
      await finish(interrupted: true);
      await closeCamera();
    } else {
      await closeCamera();
      complete();
    }
  }

  void releaseHold() {
    if (mounted && widget.held?.value == false && clock.isRunning && !busy) {
      unawaited(finish(discard: widget.cancelled?.value == true));
    }
  }

  Future<void> switchCamera() async {
    if (busy) return;
    setState(() => busy = true);
    final next = (index + 1) % cameras.length;
    try {
      if (clock.isRunning) {
        await camera!
            .setDescription(cameras[next])
            .timeout(const Duration(seconds: 15));
        index = next;
      } else {
        await closeCamera().timeout(const Duration(seconds: 5));
        if (!mounted) return;
        index = next;
        await open();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Не удалось переключить камеру. Повторите или отмените запись.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
      releaseHold();
    }
  }

  Future<void> start() async {
    setState(() => busy = true);
    try {
      await camera!.startVideoRecording().timeout(const Duration(seconds: 15));
      if (!mounted) return;
      clock.start();
      if (_discard) {
        busy = false;
        await finish(discard: true);
        return;
      }
      widget.onRecording?.call(true);
      timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) setState(() {});
        if (clock.elapsed.inSeconds >= widget.maxSeconds && !busy) finish();
      });
    } catch (_) {
      if (mounted) setState(() => error = 'Не удалось начать запись');
    } finally {
      if (mounted) setState(() => busy = false);
      releaseHold();
    }
  }

  Future<void> finish({bool discard = false, bool interrupted = false}) async {
    if (busy) return;
    setState(() => busy = true);
    timer?.cancel();
    clock.stop();
    widget.onRecording?.call(false);
    try {
      final recorded = await camera!.stopVideoRecording().timeout(
        const Duration(seconds: 15),
      );
      final size = await recorded.length();
      if (discard || _discard || !mounted) {
        await deleteRecording(recorded.path);
        complete();
        return;
      }
      final source = PickedFile(
        name:
            'video-note-${DateTime.now().millisecondsSinceEpoch}.${recorded.path.endsWith('.mp4') ? 'mp4' : 'webm'}',
        mime:
            recorded.mimeType ??
            (recorded.path.endsWith('.mp4') ? 'video/mp4' : 'video/webm'),
        size: size,
        read: (start, end) async {
          final bytes = BytesBuilder(copy: false);
          await for (final block in recorded.openRead(start, end)) {
            bytes.add(block);
          }
          return bytes.takeBytes();
        },
        release: () => deleteRecording(recorded.path),
      );
      if (mounted) {
        complete((
          file: source,
          interrupted: interrupted,
          duration: clock.elapsedMilliseconds.clamp(
            1,
            widget.maxSeconds * 1000,
          ),
        ));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = 'Запись не удалось завершить';
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive && clock.isRunning) {
      finish(interrupted: true);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: AppDialogTitle(child: const Text('Видеокружок')),
    content: SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: (MediaQuery.sizeOf(context).height * .38).clamp(80, 320),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipOval(
                  child: camera?.value.isInitialized == true
                      ? CameraPreview(camera!)
                      : const Center(child: CircularProgressIndicator()),
                ),
                CircularProgressIndicator(
                  value: clock.elapsedMilliseconds / (widget.maxSeconds * 1000),
                  strokeWidth: 6,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text('${clock.elapsed.inSeconds} с / ${widget.maxSeconds} с'),
          Text(
            widget.held == null
                ? 'Нажмите «Отправить», когда закончите.'
                : 'Отпустите, чтобы отправить. Сдвиньте влево для отмены.',
          ),
          if (error != null) Text(error!),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          _discard = true;
          if (!busy) {
            clock.isRunning ? finish(discard: true) : complete();
          }
        },
        child: const Text('Отмена'),
      ),
      if (error != null && !clock.isRunning)
        TextButton(
          onPressed: busy ? null : init,
          child: const Text('Повторить'),
        ),
      if (cameras.length > 1)
        IconButton(
          tooltip: 'Переключить камеру',
          onPressed: busy ? null : switchCamera,
          icon: const Icon(Icons.cameraswitch),
        ),
      FilledButton(
        onPressed: busy || camera?.value.isInitialized != true
            ? null
            : () => clock.isRunning ? finish() : start(),
        child: Text(clock.isRunning ? 'Отправить' : 'Записать'),
      ),
    ],
  );
  @override
  void dispose() {
    releaseCapture(captureCancellation);
    clock.stop();
    widget.onRecording?.call(false);
    WidgetsBinding.instance.removeObserver(this);
    widget.held?.removeListener(releaseHold);
    timer?.cancel();
    if (camera != null) {
      cameraDisposal = camera!.dispose();
      camera = null;
    }
    unawaited(
      cameraDisposal
          ?.timeout(const Duration(seconds: 5))
          .catchError((Object _) {}),
    );
    super.dispose();
  }
}
