import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption/cross_signing.dart';
import 'package:matrix/encryption/key_verification_manager.dart';

import 'first_keys_test.dart' show PinClient;
import 'device_verification_test.dart' show SignedDevice;

class RaceClient extends PinClient {
  @override
  String get userID => '@me:local';
  @override
  String get deviceID => 'SELF';
  @override
  String generateUniqueTransactionId() => 'verification-transaction';
  @override
  Set<KeyVerificationMethod> get verificationMethods => {
    KeyVerificationMethod.emoji,
    KeyVerificationMethod.qrShow,
    KeyVerificationMethod.qrScan,
  };
}

class DisabledCrossSigning implements CrossSigning {
  @override
  bool get enabled => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RaceEncryption implements Encryption {
  @override
  final Client client;
  @override
  final CrossSigning crossSigning = DisabledCrossSigning();
  @override
  late final keyVerificationManager = KeyVerificationManager(this);
  RaceEncryption(this.client);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DelayedVerification extends KeyVerification {
  final sending = Completer<void>();
  final response = Completer<void>();
  DelayedVerification(Encryption encryption)
    : super(encryption: encryption, userId: '@me:local', deviceId: 'OTHER');
  @override
  Future<QRCode?> generateQrCode() async => null;
  @override
  Future<void> send(String type, Map<String, dynamic> payload) async {
    sending.complete();
    await response.future;
  }
}

void main() {
  late RaceClient client;
  late RaceEncryption encryption;
  late DelayedVerification request;
  setUp(() {
    client = RaceClient();
    final peer = SignedDevice(client.userID, 'OTHER', 'peer-key');
    client.userDeviceKeys[client.userID] = DeviceKeysList(
      client.userID,
      client,
      deviceKeys: {'OTHER': peer},
    );
    encryption = RaceEncryption(client);
    request = DelayedVerification(encryption);
  });

  test(
    'ready is routed before the outgoing request HTTP response completes',
    () async {
      final starting = request.start();
      await request.sending.future;
      await encryption.keyVerificationManager.handleToDeviceEvent(
        ToDeviceEvent(
          sender: client.userID,
          type: EventTypes.KeyVerificationReady,
          content: {
            'transaction_id': request.transactionId,
            'from_device': 'OTHER',
            'methods': [
              EventTypes.QRShow,
              EventTypes.QRScan,
              EventTypes.Reciprocate,
            ],
          },
        ),
      );
      expect(request.state, KeyVerificationState.askChoice);
      expect(request.startedVerification, isTrue);
      request.response.complete();
      await starting;
      expect(request.state, KeyVerificationState.askChoice);
      expect(peerVerified(client), isFalse);
    },
  );

  test('failed initial send fences the registered transaction', () async {
    final starting = request.start();
    final failure = expectLater(starting, throwsStateError);
    await request.sending.future;
    request.response.completeError(StateError('offline'));
    await failure;
    expect(request.isDone, isTrue);
    await encryption.keyVerificationManager.handleToDeviceEvent(
      ToDeviceEvent(
        sender: client.userID,
        type: EventTypes.KeyVerificationReady,
        content: {
          'transaction_id': request.transactionId,
          'from_device': 'OTHER',
          'methods': [
            EventTypes.QRShow,
            EventTypes.QRScan,
            EventTypes.Reciprocate,
          ],
        },
      ),
    );
    expect(request.state, KeyVerificationState.error);
    await encryption.keyVerificationManager.cleanup();
    expect(
      encryption.keyVerificationManager.getRequest(request.transactionId!),
      isNull,
    );
    expect(peerVerified(client), isFalse);
  });

  test(
    'ready HTTP completion preserves progress made by incoming start/key',
    () async {
      request.lastStep = EventTypes.KeyVerificationRequest;
      request.state = KeyVerificationState.askAccept;
      request.possibleMethods = [EventTypes.Sas];
      final accepting = request.acceptVerification();
      await request.sending.future;
      // The encrypted sync stream and the send HTTP response are independent.
      request.lastStep = 'm.key.verification.key';
      request.setState(KeyVerificationState.askSas);
      request.response.complete();
      await accepting;
      expect(request.state, KeyVerificationState.askSas);
      expect(peerVerified(client), isFalse);
    },
  );

  test(
    'SAS start HTTP completion does not overwrite received SAS state',
    () async {
      request.transactionId = 'sas-transaction';
      request.state = KeyVerificationState.askChoice;
      request.possibleMethods = [EventTypes.Sas];
      final continuing = request.continueVerification(EventTypes.Sas);
      await request.sending.future;
      request.setState(KeyVerificationState.askSas);
      request.response.complete();
      await continuing;
      expect(request.state, KeyVerificationState.askSas);
      expect(peerVerified(client), isFalse);
    },
  );
}

bool peerVerified(RaceClient client) =>
    client.userDeviceKeys[client.userID]!.deviceKeys['OTHER']!.directVerified;
