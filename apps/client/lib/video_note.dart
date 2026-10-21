import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'picked_file.dart';
import 'file_io.dart';
import 'active_capture.dart';

Future<({PickedFile file, int duration, bool interrupted})?> recordVideoNote(
  BuildContext context,
  int maxSeconds, {
  ValueNotifier<bool>? held,
  void Function(bool)? onRecording,
}) async {
  await stopActiveCapture();
  if (!context.mounted) return null;
  return showDialog<({PickedFile file, int duration, bool interrupted})>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _Recorder(maxSeconds: maxSeconds, held: held, onRecording: onRecording),
  );
}

class _Recorder extends StatefulWidget {
  final int maxSeconds;
  final ValueNotifier<bool>? held;
  final void Function(bool)? onRecording;
  const _Recorder({required this.maxSeconds, this.held, this.onRecording});
  @override
  State<_Recorder> createState() => _RecorderState();
}

class _RecorderState extends State<_Recorder> with WidgetsBindingObserver {
  List<CameraDescription> cameras = [];
  CameraController? camera;
  Future<void>? cameraDisposal;
  bool busy = false;
  String? error;
  final clock = Stopwatch();
  Timer? timer;
  int index = 0;
  late final Future<void> initializing;
  late final Future<void> Function() captureCancellation = cancelForCall;
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
      if (mounted && widget.held != null) {
        if (widget.held!.value) {
          await start();
        } else {
          Navigator.pop(context);
        }
      }
    } catch (_) {
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
      if (mounted) Navigator.pop(context);
    }
  }

  void releaseHold() {
    if (mounted && widget.held?.value == false && clock.isRunning && !busy) {
      unawaited(finish());
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
      if (discard || !mounted) {
        await deleteRecording(recorded.path);
        if (mounted) Navigator.pop(context);
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
        Navigator.pop(context, (
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
    title: const Text('Видеокружок'),
    content: SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1,
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
          if (error != null) Text(error!),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy
            ? () => Navigator.pop(context)
            : () => clock.isRunning
                  ? finish(discard: true)
                  : Navigator.pop(context),
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
        child: Text(clock.isRunning ? 'Прикрепить' : 'Записать'),
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
