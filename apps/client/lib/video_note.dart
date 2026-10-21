import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'picked_file.dart';
import 'file_io.dart';

Future<({PickedFile file, int duration})?> recordVideoNote(
  BuildContext context,
  int maxSeconds, {
  ValueNotifier<bool>? held,
  void Function(bool)? onRecording,
}) => showDialog<({PickedFile file, int duration})>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      _Recorder(maxSeconds: maxSeconds, held: held, onRecording: onRecording),
);

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
  bool busy = false;
  String? error;
  final clock = Stopwatch();
  Timer? timer;
  int index = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.held?.addListener(releaseHold);
    init();
  }

  Future<void> init() async {
    try {
      cameras = await availableCameras();
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
        setState(() => error = 'Разрешите доступ к камере и микрофону.');
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
    await next.initialize();
    if (mounted) {
      setState(() {});
    } else {
      await next.dispose();
    }
  }

  void releaseHold() {
    if (widget.held?.value == false && clock.isRunning && !busy) {
      unawaited(finish());
    }
  }

  Future<void> switchCamera() async {
    if (busy) return;
    setState(() => busy = true);
    final next = (index + 1) % cameras.length;
    try {
      if (clock.isRunning) {
        await camera!.setDescription(cameras[next]);
        index = next;
      } else {
        await camera?.dispose();
        index = next;
        await open();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Камера не переключилась. Текущая запись сохранена.',
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
      await camera!.startVideoRecording();
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

  Future<void> finish({bool discard = false}) async {
    if (busy) return;
    setState(() => busy = true);
    timer?.cancel();
    clock.stop();
    widget.onRecording?.call(false);
    try {
      final recorded = await camera!.stopVideoRecording();
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
      finish(discard: true);
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
            ? null
            : () => clock.isRunning
                  ? finish(discard: true)
                  : Navigator.pop(context),
        child: const Text('Отмена'),
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
    widget.onRecording?.call(false);
    WidgetsBinding.instance.removeObserver(this);
    widget.held?.removeListener(releaseHold);
    timer?.cancel();
    camera?.dispose();
    super.dispose();
  }
}
