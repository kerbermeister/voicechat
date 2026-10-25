import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/device_verification.dart';

import 'chat_actions_test.dart' show OutboxDatabase;
import 'device_verification_test.dart' show Proof;
import 'first_keys_test.dart' show PinDevice;

class FrameClient extends Client {
  FrameClient()
    : super('verification-without-frames', database: OutboxDatabase());
  @override
  String get userID => '@self:local';
}

class FrameDevice extends PinDevice {
  late final proof = FrameProof(this);
  FrameDevice() : super('@self:local', 'OTHER', 'key');
  @override
  Future<KeyVerification> startVerification() async => proof;
}

class FrameProof extends Proof {
  FrameProof(super.device) {
    state = KeyVerificationState.askSSSS;
  }
  bool _startedVerification = true;
  @override
  bool get startedVerification => _startedVerification;
  @override
  set startedVerification(bool value) => _startedVerification = value;
  final initialSend = Completer<void>();
  final sasSend = Completer<void>();
  int opens = 0, starts = 0;
  bool fail = false;
  @override
  Future<bool> verifyActivity() async => !isDone;
  void change(KeyVerificationState next) {
    state = next;
    onUpdate?.call();
  }

  @override
  Future<void> openSSSS({
    String? passphrase,
    String? recoveryKey,
    String? keyOrPassphrase,
    bool skip = false,
  }) async {
    expect(skip, isTrue);
    opens++;
    change(KeyVerificationState.waitingAccept);
    await initialSend.future;
  }

  @override
  Future<void> continueVerification(
    String type, {
    Uint8List? qrDataRawBytes,
  }) async {
    expect(type, EventTypes.Sas);
    starts++;
    if (fail) throw StateError('offline');
    change(KeyVerificationState.waitingAccept);
    await sasSend.future;
  }
}

void main() {
  late FrameClient client;
  late FrameDevice device;
  late DeviceVerifications owner;
  setUp(() {
    client = FrameClient();
    device = FrameDevice();
    client.userDeviceKeys[client.userID] = DeviceKeysList(
      client.userID,
      client,
      deviceKeys: {device.deviceId: device},
    );
    owner = DeviceVerifications(client, () {});
  });
  tearDown(() async {
    if (!device.proof.initialSend.isCompleted) {
      device.proof.initialSend.complete();
    }
    if (!device.proof.sasSend.isCompleted) device.proof.sasSend.complete();
    await owner.close();
  });

  test(
    'Own verification starts SAS without a dialog or animation frames',
    () async {
      final request = await owner.start(device) as FrameProof;
      await Future<void>.delayed(Duration.zero);
      expect(request.opens, 1);
      expect(owner.viewing, isNull);
      // Ready arrives while the initial HTTP send is still completing.
      request.change(KeyVerificationState.askChoice);
      request.onUpdate?.call();
      expect(request.starts, 0);
      request.initialSend.complete();
      await Future<void>.delayed(Duration.zero);
      expect(request.starts, 1);
      request.onUpdate?.call();
      await Future<void>.delayed(Duration.zero);
      expect(request.starts, 1);
      request.change(KeyVerificationState.askSas);
      request.sasSend.complete();
      await Future<void>.delayed(Duration.zero);
      expect(request.state, KeyVerificationState.askSas);
      expect(device.directVerified, isFalse);
      expect(owner.completed, isEmpty);
    },
  );

  test('An incoming request still needs explicit acceptance', () async {
    device.proof
      ..state = KeyVerificationState.askAccept
      ..startedVerification = false;
    await owner.start(device);
    await Future<void>.delayed(Duration.zero);
    expect(device.proof.opens, 0);
    expect(device.proof.starts, 0);
    expect(device.directVerified, isFalse);
  });

  test('Cancellation during the initial send prevents automatic SAS', () async {
    final request = await owner.start(device) as FrameProof;
    await Future<void>.delayed(Duration.zero);
    request.change(KeyVerificationState.askChoice);
    await request.cancel('m.user');
    request.initialSend.complete();
    await Future<void>.delayed(Duration.zero);
    expect(request.starts, 0);
    expect(device.directVerified, isFalse);
  });

  test(
    'A failed automatic step is visible and is not retried in a loop',
    () async {
      device.proof
        ..state = KeyVerificationState.askChoice
        ..fail = true;
      await owner.start(device);
      await Future<void>.delayed(Duration.zero);
      expect(device.proof.starts, 1);
      expect(owner.errors[device.proof], isNotNull);
      device.proof.onUpdate?.call();
      await Future<void>.delayed(Duration.zero);
      expect(device.proof.starts, 1);
      expect(device.directVerified, isFalse);
    },
  );
}
