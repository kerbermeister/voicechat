// Human actions are driven through real web/Android UI; never report the SAS values.
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:matrix/encryption.dart';
import 'device_verification.dart';
import 'device_verification_dialog.dart';
import 'first_keys.dart';
import 'matrix_probe.dart';
import 'lab_main.dart' as lab;
import 'lab_qr_decode_stub.dart'
    if (dart.library.io) 'lab_qr_decode_native.dart';

Future<void> verifyLabDevices(
  MatrixProbe probe,
  int index,
  BuildContext context,
) async {
  if (index < 2) {
    const qr = bool.fromEnvironment('QR_TEST');
    final phase = qr ? 'qr' : 'sas';
    if (qr) {
      await probe.initializeRecovery(lab.passwords[index]);
      await lab.report('video_qr_root_$index');
      await lab.barrier('video_qr_root_${1 - index}');
    }
    final peer = (await lab.barrier(
      index == 0 ? 'bob-android-identity' : 'alice-web-identity',
    ));
    await refreshDevices(probe.client, {peer['user_id'] as String});
    final device = probe
        .client
        .userDeviceKeys[peer['user_id']]!
        .deviceKeys[peer['device_id']]!;
    lab.require(
      device.ed25519Key == peer['fingerprint'],
      'Fixture signing key changed',
    );
    enableFirstContactTrust(probe.client);
    final incoming = Completer<void>();
    late final DeviceVerifications owner;
    Future<void> show(KeyVerification request) async {
      lab.require(
        request.userId == device.userId && request.deviceId == device.deviceId,
        'Unexpected verification device',
      );
      final dialog = showDeviceVerification(context, owner, request);
      final comparison = qr
          ? KeyVerificationState.askChoice
          : KeyVerificationState.askSas;
      await lab.until(
        () async => request.state == comparison || request.isDone,
        'Verification did not reach comparison',
      );
      lab.require(
        request.state == comparison,
        'Verification cancelled before comparison',
      );
      await lab.report('video_${phase}_codes_$index');
      if (qr && index == 1) {
        final bytes = await readLabDeviceQr();
        try {
          await request.continueVerification(
            'm.reciprocate.v1',
            qrDataRawBytes: bytes,
          );
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
        await lab.report('video_qr_scanned_1');
      }
      await dialog;
      lab.require(
        !request.canceled && request.state == KeyVerificationState.done,
        'UI closed without a completed SAS',
      );
      final current = probe
          .client
          .userDeviceKeys[device.userId]!
          .deviceKeys[device.deviceId]!;
      lab.require(
        current.ed25519Key == peer['fingerprint'] &&
            (await independentlyVerifiedDevices(probe.client, [
              current,
            ])).contains(current),
        'SAS did not pin the authentic fixture key',
      );
    }

    owner = DeviceVerifications(probe.client, () {
      unawaited(() async {
        try {
          await lab.report('video_${phase}_invited_$index');
          await show(owner.pending.single);
          incoming.complete();
        } catch (error, stack) {
          incoming.completeError(error, stack);
        }
      }());
    });
    try {
      await lab.report('video_${phase}_owner_$index');
      await lab.barrier('video_${phase}_owner_${1 - index}');
      if (index == 0) {
        await show(await owner.start(device));
      } else {
        await incoming.future;
      }
      await lab.report('video_${phase}_done_$index');
    } finally {
      await owner.close();
    }
  }
  final phase = const bool.fromEnvironment('QR_TEST') ? 'qr' : 'sas';
  await lab.barrier('video_${phase}_done_0');
  await lab.barrier('video_${phase}_done_1');
}
