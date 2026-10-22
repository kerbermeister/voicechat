import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart' as qr_ui;
import 'package:voicechat_probe/device_qr_scanner.dart';
import 'package:voicechat_probe/device_verification.dart';
import 'package:voicechat_probe/active_capture.dart';
import 'chat_actions_test.dart' show OutboxDatabase;
import 'first_keys_test.dart' show PinClient, PinDevice;
import 'device_verification_test.dart' show VerificationEncryption;

String key(int value) =>
    base64Encode(List.filled(32, value)).replaceAll('=', '');

class QrClient extends PinClient {
  @override
  String get userID => '@self:local';
  @override
  String get deviceID => 'SELF';
}

class QrMaster implements CrossSigningKey {
  @override
  final String userId;
  @override
  final String ed25519Key;
  QrMaster(this.userId, this.ed25519Key);
  @override
  bool verified = true;
  @override
  bool get isValid => true;
  @override
  bool blocked = false;
  @override
  List<String> get usage => ['master'];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class QrRequest extends KeyVerification {
  final proven = <SignableKey>[];
  QrRequest(Client client, String user)
    : super(
        encryption: VerificationEncryption(client),
        userId: user,
        deviceId: 'OTHER',
      ) {
    transactionId = 'current-request';
    state = KeyVerificationState.askChoice;
  }
  @override
  Future<void> verifyKeysQR(SignableKey key, {bool shower = true}) async {
    proven.add(key);
  }
}

Uint8List qr(
  int mode,
  int first,
  int second, {
  String transaction = 'current-request',
}) {
  final txn = utf8.encode(transaction);
  return Uint8List.fromList([
    ...ascii.encode('MATRIX'),
    2,
    mode,
    txn.length >> 8,
    txn.length & 255,
    ...txn,
    ...List.filled(32, first),
    ...List.filled(32, second),
    ...List.filled(11, 99),
  ]);
}

class SlowCamera extends MobileScannerPlatform {
  final stopping = Completer<void>();
  @override
  Stream<BarcodeCapture?> get barcodesStream => const Stream.empty();
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const SizedBox.expand();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async =>
      const MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: TorchState.unavailable,
        size: Size(320, 640),
        numberOfCameras: 1,
      );
  @override
  Future<void> stop() => stopping.future;
  @override
  Future<void> dispose() async {}
  @override
  Future<void> updateScanWindow(Rect? window) async {}
}

void main() {
  testWidgets(
    'An incoming capture waits for camera release already started by scanner dismissal',
    (tester) async {
      final previous = MobileScannerPlatform.instance;
      final camera = SlowCamera();
      MobileScannerPlatform.instance = camera;
      addTearDown(() => MobileScannerPlatform.instance = previous);
      final owner = DeviceVerifications(
        Client('camera-owner', database: OutboxDatabase()),
        () {},
      );
      final request = QrRequest(QrClient(), '@peer:local');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => scanDeviceQr(context, owner, request),
                child: const Text('Scan'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Scan'));
      await tester.pumpAndSettle();
      final controller = tester
          .widget<MobileScanner>(find.byType(MobileScanner))
          .controller!;
      expect(controller.value.isRunning, true);
      await tester.tap(find.text('Отмена'));
      await tester.pump();
      var released = false;
      final stopping = stopActiveCapture().then((_) => released = true);
      await tester.pump();
      expect(released, false);
      camera.stopping.complete();
      await tester.runAsync(() => stopping);
      await tester.pumpAndSettle();
      expect(released, true);
      expect(find.byType(MobileScanner), findsNothing);
      await tester.runAsync(owner.close);
    },
  );
  testWidgets(
    'Render a public synthetic binary Matrix QR for cross-decoder acceptance',
    (tester) async {
      final code = qr_ui.QrCode.fromUint8List(
        data: qr(0, 2, 1),
        errorCorrectLevel: qr_ui.QrErrorCorrectLevel.M,
      );
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder)
        ..drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
      canvas.translate(32, 32);
      qr_ui.QrPainter.withQr(
        qr: code,
        gapless: true,
      ).paint(canvas, const ui.Size(448, 448));
      await tester.runAsync(() async {
        final image = await recorder.endRecording().toImage(512, 512);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        expect(png, isNotNull);
        await File(
          '../../.prototype/qr-fixture.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
    },
  );
  test(
    'Matrix QR validates both keys, mode, transaction and bounds before granting trust',
    () async {
      final client = QrClient();
      final ownMaster = QrMaster(client.userID, key(1));
      final peerMaster = QrMaster('@peer:local', key(2));
      final self = PinDevice(client.userID, 'SELF', key(3));
      final other = PinDevice(client.userID, 'OTHER', key(4));
      client.userDeviceKeys[client.userID] = DeviceKeysList(
        client.userID,
        client,
        deviceKeys: {'SELF': self, 'OTHER': other},
        crossSigningKeys: {'master': ownMaster},
      );
      client.userDeviceKeys[peerMaster.userId] = DeviceKeysList(
        peerMaster.userId,
        client,
        crossSigningKeys: {'master': peerMaster},
      );
      final request = QrRequest(client, peerMaster.userId);
      final valid = qr(0, 2, 1);
      for (final data in [
        qr(0, 8, 1),
        qr(0, 2, 8),
        qr(0, 2, 1, transaction: 'old-request'),
        qr(1, 1, 3),
        qr(2, 4, 1),
        qr(255, 2, 1),
        Uint8List.fromList(valid)..[8] = 255,
        Uint8List.fromList(valid)..[6] = 3,
        Uint8List.fromList(valid)..[0] = 0,
        Uint8List(4097),
        for (var n = 0; n < valid.length - 3; n++)
          Uint8List.sublistView(valid, 0, n),
      ]) {
        expect(await request.verifyQrData(data), false);
        expect(request.proven, isEmpty);
        expect(request.randomSharedSecretForQRCode, isNull);
      }
      ownMaster.verified = false;
      expect(await request.verifyQrData(valid), false);
      ownMaster.verified = true;
      peerMaster.blocked = true;
      expect(await request.verifyQrData(valid), false);
      peerMaster.blocked = false;
      expect(await request.verifyQrData(valid), true);
      expect(request.proven.single, same(peerMaster));
      request.state = KeyVerificationState.done;
      expect(await request.verifyQrData(valid), false);
      expect(request.proven.length, 1);
      final selfRequest = QrRequest(client, client.userID);
      ownMaster.verified = false;
      expect(await selfRequest.verifyQrData(qr(1, 1, 3)), true);
      expect(selfRequest.proven.single, same(ownMaster));
      final second = QrRequest(client, client.userID);
      expect(await second.verifyQrData(qr(2, 4, 1)), false);
      ownMaster.verified = true;
      expect(await second.verifyQrData(qr(2, 4, 1)), true);
      expect(second.proven.single, same(other));
      second.canceled = true;
      expect(await second.verifyQrData(qr(2, 4, 1)), false);
    },
  );

  test(
    'Scanner consumes binary decoded bytes only, never URL text or encoded Vision payload',
    () {
      final bytes = qr(0, 2, 1);
      final readOnly = bytes.asUnmodifiableView();
      final owned = decodedQrBytes(
        Barcode(rawDecodedBytes: DecodedBarcodeBytes(bytes: readOnly)),
      )!;
      owned.fillRange(0, owned.length, 0);
      expect(owned.every((byte) => byte == 0), true);
      expect(readOnly, qr(0, 2, 1));
      expect(
        decodedQrBytes(
          Barcode(rawDecodedBytes: DecodedBarcodeBytes(bytes: bytes)),
        ),
        bytes,
      );
      expect(
        decodedQrBytes(const Barcode(rawValue: 'https://unexpected.example')),
        isNull,
      );
      expect(
        decodedQrBytes(
          Barcode(rawDecodedBytes: DecodedVisionBarcodeBytes(rawBytes: bytes)),
        ),
        isNull,
      );
      expect(
        decodedQrBytes(
          Barcode(
            rawDecodedBytes: DecodedVisionBarcodeBytes(
              rawBytes: Uint8List(5),
              bytes: bytes,
            ),
          ),
        ),
        bytes,
      );
      expect(
        decodedQrBytes(
          Barcode(rawDecodedBytes: DecodedBarcodeBytes(bytes: Uint8List(4097))),
        ),
        isNull,
      );
    },
  );
}
