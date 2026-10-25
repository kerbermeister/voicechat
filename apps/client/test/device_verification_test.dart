import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'package:voicechat_probe/device_verification.dart';
import 'package:voicechat_probe/first_keys.dart';
import 'package:voicechat_probe/device_verification_dialog.dart';
import 'chat_actions_test.dart' show OutboxDatabase;
import 'first_keys_test.dart' show PinClient, PinDevice;

class Proof implements KeyVerification {
  @override
  void Function()? onUpdate;
  @override
  String? canceledCode;
  @override
  String? lastStep;
  @override
  bool get isDone =>
      canceled ||
      {KeyVerificationState.done, KeyVerificationState.error}.contains(state);
  @override
  List<int> get sasNumbers => [1234, 5678, 9012];
  @override
  List<KeyVerificationEmoji> get sasEmojis => [
    for (var i = 0; i < 7; i++) KeyVerificationEmoji(i),
  ];
  @override
  Future<void> cancel([String code = 'm.unknown', bool quiet = false]) async {
    canceled = true;
    canceledCode = code;
    state = KeyVerificationState.error;
  }

  @override
  final String userId, deviceId;
  @override
  List<SignableKey> verifiedKeys;
  @override
  bool canceled = false;
  @override
  KeyVerificationState state = KeyVerificationState.done;
  @override
  DateTime createdAt = DateTime.now();
  Proof(DeviceKeys device)
    : userId = device.userId,
      deviceId = device.deviceId!,
      verifiedKeys = [device];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class VerificationEncryption implements Encryption {
  @override
  final Client client;
  VerificationEncryption(this.client);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ProvenMaster implements CrossSigningKey {
  @override
  final String userId;
  @override
  final String publicKey = 'authenticated-master';
  ProvenMaster(this.userId);
  @override
  List<String> get usage => ['master'];
  bool valid = true;
  @override
  bool get isValid => valid;
  @override
  bool get blocked => false;
  @override
  bool directVerified = false;
  @override
  Future<void> setVerified(bool value, [bool sign = true]) async =>
      directVerified = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class SignedDevice extends PinDevice {
  SignedDevice(super.userId, super.deviceId, super.ed25519Key);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName == #hasValidSignatureChain
      ? true
      : super.noSuchMethod(invocation);
}

class WaitingVerification extends KeyVerification {
  final sent = <String>[];
  final network = Completer<void>();
  WaitingVerification(Encryption encryption)
    : super(encryption: encryption, userId: '@peer:local', deviceId: 'D');
  @override
  Future<void> send(String type, Map<String, dynamic> payload) async {
    sent.add(type);
    await network.future;
  }
}

void main() {
  test(
    'An invalid master cannot prove a device even when a signature-chain lookup succeeds',
    () async {
      final client = PinClient();
      enableFirstContactTrust(client);
      final device = SignedDevice('@peer:local', 'D', 'key');
      final master = ProvenMaster(device.userId)..valid = false;
      client.userDeviceKeys[device.userId] = DeviceKeysList(
        device.userId,
        client,
        deviceKeys: {'D': device},
        crossSigningKeys: {master.publicKey: master},
      );
      final proof = Proof(device)..verifiedKeys = [master];
      await expectLater(
        finishDeviceVerification(
          client,
          proof,
          device.userId,
          device.deviceId,
          device.ed25519Key,
          device.curve25519Key,
        ),
        throwsA(anything),
      );
      expect(device.directVerified, false);
      expect(await independentlyVerifiedDevices(client, [device]), isEmpty);
    },
  );
  test(
    'An authenticated master enables its signed new devices after an earlier TOFU contact',
    () async {
      final client = PinClient();
      enableFirstContactTrust(client);
      final first = PinDevice('@peer:local', 'D', 'key')..directVerified = true;
      final list = DeviceKeysList(
        first.userId,
        client,
        deviceKeys: {'D': first},
      );
      client.userDeviceKeys[first.userId] = list;
      await acceptFirstKeys(client, {first.userId});
      final master = ProvenMaster(first.userId);
      list.crossSigningKeys[master.publicKey] = master;
      final newDevice = SignedDevice(first.userId, 'NEW', 'new-key');
      list.deviceKeys['NEW'] = newDevice;
      await acceptFirstKeys(client, {first.userId});
      expect(newDevice.directVerified, false);
      final proof = Proof(first)..verifiedKeys = [first, master];
      await finishDeviceVerification(
        client,
        proof,
        first.userId,
        first.deviceId,
        first.ed25519Key,
        first.curve25519Key,
      );
      await acceptFirstKeys(client, {first.userId});
      expect(master.directVerified, true);
      expect(newDevice.directVerified, true);
    },
  );
  testWidgets(
    'SAS codes and seven emoji fit a phone and remain accessible as text',
    (tester) async {
      final owner = DeviceVerifications(
        Client('sas-ui', database: OutboxDatabase()),
        () {},
      );
      final proof = Proof(PinDevice('@peer:local', 'D', 'key'))
        ..state = KeyVerificationState.askSas;
      bool? verified;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  verified = await showDeviceVerification(
                    context,
                    owner,
                    proof,
                  );
                },
                child: const Text('Start'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(find.text('1234  5678  9012'), findsNothing);
      for (final emoji in proof.sasEmojis) {
        expect(find.text(emoji.emoji), findsOneWidget);
      }
      await tester.ensureVisible(find.text('Код'));
      await tester.tap(find.text('Код'));
      await tester.pumpAndSettle();
      expect(find.text('1234  5678  9012'), findsOneWidget);
      for (final emoji in proof.sasEmojis) {
        expect(find.text(emoji.emoji), findsNothing);
      }
      await tester.ensureVisible(find.text('Эмодзи'));
      await tester.tap(find.text('Эмодзи'));
      await tester.pumpAndSettle();
      expect(find.text('1234  5678  9012'), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(proof.canceled, true);
      expect(verified, false);
      await tester.runAsync(owner.close);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
  test(
    'Sync cleanup cannot prolong the original ten-minute verification deadline',
    () async {
      final client = Client(
        'deadline-test',
        database: OutboxDatabase(),
        verificationMethods: {KeyVerificationMethod.numbers},
      );
      client.userDeviceKeys['@peer:local'] = DeviceKeysList(
        '@peer:local',
        client,
        deviceKeys: {'D': PinDevice('@peer:local', 'D', 'key')},
      );
      final request = WaitingVerification(VerificationEncryption(client));
      request.network.complete();
      final created = DateTime.now().subtract(
        const Duration(minutes: 9, seconds: 59),
      );
      await request.handlePayload(EventTypes.KeyVerificationRequest, {
        'timestamp': created.millisecondsSinceEpoch,
        'from_device': 'D',
        'transaction_id': 'deadline-test',
        'methods': [EventTypes.Sas],
      });
      request.lastActivity = DateTime.now();
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(await request.verifyActivity(), false);
      expect(request.canceledCode, 'm.timeout');
    },
  );
  test(
    'A completed protocol must prove the unchanged device key, not just a TOFU flag',
    () async {
      final client = PinClient();
      enableFirstContactTrust(client);
      final device = PinDevice('@peer:local', 'D', 'key');
      client.userDeviceKeys[device.userId] = DeviceKeysList(
        device.userId,
        client,
        deviceKeys: {'D': device},
      );
      Future<void> finish(Proof proof) => finishDeviceVerification(
        client,
        proof,
        device.userId,
        device.deviceId,
        device.ed25519Key,
        device.curve25519Key,
      );
      for (final proof in [
        Proof(device)..state = KeyVerificationState.waitingSas,
        Proof(device)..canceled = true,
        Proof(device)
          ..createdAt = DateTime.now().subtract(const Duration(minutes: 11)),
        Proof(device)..verifiedKeys = [],
        Proof(device)
          ..verifiedKeys = [PinDevice('@peer:local', 'other', 'key')],
      ]) {
        await expectLater(finish(proof), throwsA(anything));
      }
      expect(device.directVerified, false);
      device.directVerified = true;
      await expectLater(
        finish(Proof(device)..verifiedKeys = []),
        throwsA(anything),
      );
      expect(await independentlyVerifiedDevices(client, [device]), isEmpty);
      device.directVerified = false;
      client.database.failWrite = true;
      await expectLater(finish(Proof(device)), throwsStateError);
      expect(device.directVerified, false);
      client.database.failWrite = false;
      final replacement = PinDevice(
        device.userId,
        device.deviceId,
        'replacement',
      );
      client.userDeviceKeys[device.userId]!.deviceKeys[device.deviceId] =
          replacement;
      await expectLater(finish(Proof(device)), throwsA(anything));
      expect(replacement.directVerified, false);
      client.userDeviceKeys[device.userId]!.deviceKeys[device.deviceId] =
          device;
      await finish(Proof(device));
      expect(device.directVerified, true);
      expect(
        await independentlyVerifiedDevices(client, [device, replacement]),
        {device},
      );
    },
  );

  test(
    'Cancellation fences incoming verification before an offline send completes',
    () async {
      final client = Client('cancel-test', database: OutboxDatabase());
      final request = WaitingVerification(VerificationEncryption(client));
      final cancellation = request.cancel('m.user');
      expect(request.canceled, true);
      expect(request.state, KeyVerificationState.error);
      await request.handlePayload('m.key.verification.mac', {'mac': {}});
      await request.continueVerification(EventTypes.Sas);
      await request.acceptSas();
      await request.acceptQRScanConfirmation();
      var checked = false;
      await request.verifyKeysSAS({}, (_, _) async {
        checked = true;
        return true;
      });
      expect(checked, false);
      expect(request.verifiedKeys, isEmpty);
      await request.cancel('m.timeout');
      expect(request.canceledCode, 'm.user');
      expect(request.sent, [EventTypes.KeyVerificationCancel]);
      request.network.complete();
      await cancellation;
    },
  );
}
