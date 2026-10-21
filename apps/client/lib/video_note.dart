import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'picked_file.dart';
import 'file_io.dart';

Future<({PickedFile file, int duration})?> recordVideoNote(
  BuildContext context,
  int maxSeconds,
) => showDialog<({PickedFile file, int duration})>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _Recorder(maxSeconds: maxSeconds),
);

class _Recorder extends StatefulWidget {
  final int maxSeconds;
  const _Recorder({required this.maxSeconds});
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

  Future<void> switchCamera() async {
    if (busy || clock.isRunning) return;
    setState(() => busy = true);
    try {
      await camera?.dispose();
      index = (index + 1) % cameras.length;
      await open();
    } catch (_) {
      if (mounted) setState(() => error = 'Не удалось переключить камеру');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> start() async {
    setState(() => busy = true);
    try {
      await camera!.startVideoRecording();
      clock.start();
      timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) setState(() {});
        if (clock.elapsed.inSeconds >= widget.maxSeconds && !busy) finish();
      });
    } catch (_) {
      if (mounted) setState(() => error = 'Не удалось начать запись');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> finish({bool discard = false}) async {
    if (busy) return;
    setState(() => busy = true);
    timer?.cancel();
    clock.stop();
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
      if (cameras.length > 1 && !clock.isRunning)
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
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    camera?.dispose();
    super.dispose();
  }
}
