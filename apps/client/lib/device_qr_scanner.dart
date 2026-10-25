import 'app_motion.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:matrix/encryption.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'active_capture.dart';
import 'device_verification.dart';
import 'voice_call.dart';

Uint8List? decodedQrBytes(Barcode barcode) {
  final bytes = switch (barcode.rawDecodedBytes) {
    DecodedBarcodeBytes(:final bytes) => bytes,
    DecodedVisionBarcodeBytes(:final bytes) => bytes,
    _ => null,
  };
  // Platform buffers can be read-only; own a mutable copy for erasure after verification.
  return bytes != null && bytes.length <= 4096
      ? Uint8List.fromList(bytes)
      : null;
}

Future<Uint8List?> scanDeviceQr(
  BuildContext context,
  DeviceVerifications owner,
  KeyVerification request, {
  VoiceCall? call,
}) async {
  await stopActiveCapture();
  final resumeCamera = call?.cameraEnabled == true;
  if (resumeCamera) await call!.camera(false);
  try {
    if (!context.mounted || request.isDone) return null;
    if (kIsWeb) {
      MobileScannerPlatform.instance.setWebBarcodeReader(
        WebBarcodeReader.zxingWasm,
      );
      MobileScannerPlatform.instance.setBarcodeLibraryScriptUrl(
        Uri.base.resolve('zxing.js').toString(),
      );
    }
    return await showAppDialog<Uint8List>(
      context: context,
      animationStyle: appAnimationStyle(context),
      barrierDismissible: false,
      builder: (_) => _Scanner(owner: owner, request: request),
    );
  } finally {
    if (resumeCamera &&
        !call!.isClosed &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      await call.camera(true);
    }
  }
}

class _Scanner extends StatefulWidget {
  final DeviceVerifications owner;
  final KeyVerification request;
  const _Scanner({required this.owner, required this.request});
  @override
  State<_Scanner> createState() => _ScannerState();
}

class _ScannerState extends State<_Scanner> with WidgetsBindingObserver {
  final controller = MobileScannerController(
    formats: [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  late final Future<void> Function() captureCancellation = cancelCapture;
  Future<void> cancelCapture() => finish();
  Future<void>? cleanup;
  bool disposalAttempted = false;
  Future<void>? finishing;
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.owner.addListener(requestChanged);
    registerCapture(captureCancellation);
  }

  void requestChanged() {
    if (widget.request.isDone) unawaited(finish().catchError((Object _) {}));
  }

  Future<void> shutdown() async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!disposalAttempted && controller.value.isStarting) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Camera startup pending');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (disposalAttempted) {
      // The plugin marks itself disposed before awaiting native cleanup; retry the platform on failure.
      await MobileScannerPlatform.instance.dispose();
    } else {
      try {
        await controller.stop();
      } finally {
        disposalAttempted = true;
        await controller.dispose();
      }
    }
    releaseCapture(captureCancellation);
  }

  Future<void> finish([Uint8List? bytes]) =>
      finishing ??= _finish(bytes).whenComplete(() => finishing = null);

  Future<void> _finish(Uint8List? bytes) async {
    try {
      await (cleanup ??= shutdown());
      if (!mounted) return;
      final route = ModalRoute.of<Uint8List>(context)!;
      // An incoming-call dialog can be above this route; close only our scanner.
      route.navigator?.removeRoute(route, bytes);
    } catch (_) {
      cleanup = null;
      if (mounted) {
        setState(() => error = 'Камера ещё освобождается. Повторите закрытие.');
      }
      rethrow;
    }
  }

  void detect(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final bytes = decodedQrBytes(barcode);
      if (bytes != null) {
        unawaited(finish(bytes).catchError((Object _) {}));
        return;
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        controller.value.hasCameraPermission) {
      unawaited(finish().catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    widget.owner.removeListener(requestChanged);
    WidgetsBinding.instance.removeObserver(this);
    unawaited((cleanup ??= shutdown()).catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(finish().catchError((Object _) {}));
    },
    child: AlertDialog(
      scrollable: true,
      title: AppDialogTitle(child: const Text('Сканировать код устройства')),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Сканируйте QR в текущем окне проверки другого устройства. Содержимое кода остаётся на вашем устройстве.',
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: SizedBox(
                height: 240,
                child: MobileScanner(
                  controller: controller,
                  onDetect: detect,
                  errorBuilder: (_, _) => const Center(
                    child: Text(
                      'Нет доступа к камере. Разрешите её в настройках или сравните эмодзи.',
                    ),
                  ),
                ),
              ),
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => unawaited(finish().catchError((Object _) {})),
          child: const Text('Отмена'),
        ),
        IconButton(
          tooltip: 'Переключить камеру',
          onPressed: () async {
            try {
              await controller.switchCamera();
            } catch (_) {
              if (mounted) {
                setState(() => error = 'Не удалось переключить камеру.');
              }
            }
          },
          icon: const Icon(Icons.cameraswitch_outlined),
        ),
      ],
    ),
  );
}
