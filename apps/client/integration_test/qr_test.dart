// The fixture is public synthetic data, never a live verification secret.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:voicechat_probe/active_capture.dart';
import 'package:voicechat_probe/device_qr_scanner.dart';
import 'package:voicechat_probe/device_verification.dart';
import '../test/chat_actions_test.dart' show OutboxDatabase;
import '../test/device_qr_test.dart' show QrClient, QrRequest, qr;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android decodes Matrix binary QR and releases scanner camera before another capture',
    (tester) async {
      final data = qr(0, 2, 1);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
      canvas.translate(32, 32);
      QrPainter.withQr(
        qr: QrCode.fromUint8List(
          data: data,
          errorCorrectLevel: QrErrorCorrectLevel.M,
        ),
        gapless: true,
      ).paint(canvas, const Size(448, 448));
      final image = await recorder.endRecording().toImage(512, 512);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final path = '${Directory.systemTemp.path}/qr-fixture.png';
      await File(path).writeAsBytes(png!.buffer.asUint8List());
      final decoder = MobileScannerController(formats: [BarcodeFormat.qrCode]);
      try {
        final capture = await decoder.analyzeImage(
          path,
          formats: [BarcodeFormat.qrCode],
        );
        expect(capture, isNotNull);
        expect(decodedQrBytes(capture!.barcodes.single), data);
      } finally {
        await decoder.dispose();
        await File(path).delete();
      }
      final owner = DeviceVerifications(
        Client('qr-ui', database: OutboxDatabase()),
        () {},
      );
      final request = QrRequest(QrClient(), '@peer:local');
      var returned = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  await scanDeviceQr(context, owner, request);
                  returned = true;
                },
                child: const Text('Scan'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Scan'));
      await tester.pump();
      final controller = tester
          .widget<MobileScanner>(find.byType(MobileScanner))
          .controller!;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!controller.value.isRunning && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
      expect(controller.value.isRunning, true);
      expect(tester.takeException(), isNull);
      await stopActiveCapture();
      await tester.pumpAndSettle();
      expect(returned, true);
      expect(find.byType(MobileScanner), findsNothing);
      await owner.close();
      debugPrint(
        'PASS: Android binary QR decoder and camera ownership lifecycle',
      );
    },
  );
}
