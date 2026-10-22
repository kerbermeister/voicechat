// Debug emulator bridge: a live QR image is transferred locally, decoded and immediately removed.
import 'dart:io';
import 'dart:typed_data';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sqflite/sqflite.dart' show getDatabasesPath;
import 'device_qr_scanner.dart';
import 'lab_messaging.dart' show LabFailure;

Future<Uint8List> readLabDeviceQr() async {
  final file = File('${await getDatabasesPath()}/voicechat-live-qr.png');
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (!await file.exists()) {
    if (DateTime.now().isAfter(deadline)) {
      throw LabFailure('QR fixture did not arrive');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final controller = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  try {
    final capture = await controller.analyzeImage(
      file.path,
      formats: [BarcodeFormat.qrCode],
    );
    final bytes = capture?.barcodes.map(decodedQrBytes).nonNulls.firstOrNull;
    if (bytes == null) {
      throw LabFailure('Native decoder did not read binary QR');
    }
    return bytes;
  } finally {
    try {
      await file.delete();
    } finally {
      await controller.dispose();
    }
  }
}
