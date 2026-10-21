// Separate entrypoint: fixtures are disposable and must never ship in the app.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as mx;
import 'package:vodozemac/vodozemac.dart' as vod;
import 'matrix_probe.dart';
import 'call_probe.dart';
import 'call_controller.dart';
import 'direct_call.dart';
import 'theme.dart';
import 'local_store.dart';
import 'lab_messaging.dart';
import 'lab_recording.dart';
import 'lab_storage_stub.dart'
    if (dart.library.js_interop) 'lab_storage_web.dart';

const runId = String.fromEnvironment('RUN_ID');
final role =
    Uri.base.queryParameters['role'] ?? const String.fromEnvironment('ROLE');
const matrixUrl = String.fromEnvironment(
  'MATRIX_URL',
  defaultValue: 'http://localhost:8008',
);
const tokenUrl = String.fromEnvironment(
  'TOKEN_URL',
  defaultValue: 'http://localhost:8090',
);
const mediaUrl = String.fromEnvironment(
  'LIVEKIT_URL',
  defaultValue: 'ws://localhost:7880',
);
const users = [
  String.fromEnvironment('ALICE_USER'),
  String.fromEnvironment('BOB_USER'),
  String.fromEnvironment('CAROL_USER'),
];
const passwords = [
  String.fromEnvironment('ALICE_PASSWORD'),
  String.fromEnvironment('BOB_PASSWORD'),
  String.fromEnvironment('CAROL_PASSWORD'),
];
final progress = ValueNotifier<String>('Подготовка проверок…');
String userId(int index) => '@${users[index]}:voicechat.local';

void require(bool condition, String message) {
  if (!condition) throw LabFailure(message);
}

Future<void> report(
  String stage, [
  Map<String, dynamic> fields = const {},
]) async {
  progress.value = '$role · $stage';
  final response = await http.post(
    Uri.parse('$tokenUrl/report'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'run': runId, 'role': role, 'stage': stage, ...fields}),
  );
  require(response.statusCode == 200, 'Report unavailable');
}

Future<void> until(
  Future<bool> Function() check,
  String failure, {
  int seconds = 120,
}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw LabFailure(failure);
}

Future<Map<String, dynamic>> barrier(String stage) async {
  Map<String, dynamic>? found;
  await until(
    () async {
      final response = await http.get(Uri.parse('$tokenUrl/reports'));
      final values = (jsonDecode(response.body) as List)
          .cast<Map<String, dynamic>>()
          .where((r) => r['run'] == runId);
      if (values.any((r) => r['stage'] == 'failed')) {
        throw StateError('Other platform failed');
      }
      for (final r in values) {
        if (r['stage'] == stage) found = r;
      }
      return found != null;
    },
    'Barrier $stage',
    seconds: 600,
  );
  return found!;
}

Future<MatrixProbe> login(int index, String profile) async {
  final probe = await MatrixProbe.open(
    '$runId-$profile',
    passphrase: 'lab-vault-$runId-$index',
  );
  await probe.login(matrixUrl, users[index], passwords[index]);
  await report('$profile-identity', {
    'user_id': probe.client.userID,
    'device_id': probe.client.deviceID,
    'fingerprint': probe.client.fingerprintKey,
  });
  return probe;
}

// Only the laboratory uses this independent fixture channel for fingerprint exchange.
Future<void> trustPeers(MatrixProbe probe, {bool fresh = false}) async {
  final profiles = [
    'alice-web',
    'bob-android',
    'carol-web',
    if (fresh) 'alice-fresh-device',
  ];
  for (final profile in profiles) {
    final identity = await barrier('$profile-identity');
    await verifyDevice(
      probe.client,
      identity['user_id'] as String,
      identity['device_id'] as String,
      identity['fingerprint'] as String,
    );
  }
}

Future<void> checkRememberedTrust(MatrixProbe probe) async {
  await refreshDevices(
    probe.client,
    users.map((u) => '@$u:voicechat.local').toSet(),
  );
  for (final profile in ['alice-web', 'bob-android', 'carol-web']) {
    final identity = await barrier('$profile-identity');
    require(
      probe
              .client
              .userDeviceKeys[identity['user_id']]
              ?.deviceKeys[identity['device_id']]
              ?.directVerified ==
          true,
      'Verified device trust did not survive locked storage',
    );
  }
}

Future<mx.Event> text(mx.Room room, String body) async {
  final timeline = await room.getTimeline(limit: 1000);
  mx.Event? found;
  try {
    await until(() async {
      for (final event in timeline.events) {
        if (event.type == mx.EventTypes.Message && event.body == body) {
          found = event;
          return true;
        }
      }
      if (timeline.canRequestHistory) {
        await timeline.requestHistory(historyCount: 100);
      }
      return false;
    }, 'Message did not decrypt: $body');
    return found!;
  } finally {
    timeline.cancelSubscriptions();
  }
}

CallController controllerFor(mx.Client client) =>
    CallController(client, tokenUrl, mediaUrl, (value) {
      progress.value = value;
      unawaited(report('call_status', {'detail': value}));
    });

Future<void> android() async {
  var bob = await login(1, 'bob-android');
  CallProbe? call;
  CallController? controller;
  try {
    await checkRecording();
    await report('android_recording_playback_passed');
    await bob.initializeRecovery(passwords[1]);
    await report('android_ready');
    final roomId = (await barrier('room_created'))['room_id'] as String;
    await bob.client.joinRoom(roomId);
    var room = await bob.room(roomId);
    await trustPeers(bob);
    await text(room, 'web-to-android-$runId');
    await MatrixProbe.sendText(room, 'android-to-web-$runId');
    await bob.backup();
    await report('android_message_decrypted');
    await barrier('core_messages_passed');
    await checkAttachments(room);
    final rich = await room.getTimeline();
    require(
      rich.events.any((e) => e.getDisplayEvent(rich).body == 'edited-$runId'),
      'Android edit missing',
    );
    require(
      rich.events.any((e) => e.inReplyToEventId() != null),
      'Android reply missing',
    );
    require(rich.events.any((e) => e.redacted), 'Android redaction missing');
    await rich.setReadMarker(eventId: rich.events.first.eventId, public: true);
    rich.cancelSubscriptions();
    await room.setTyping(true, timeout: 15000);
    await report('android_attachments_passed');
    await barrier('presence_receipts_passed');
    await room.setTyping(false);
    await barrier('close_for_recovery');
    await bob.close();
    await report('android_offline');
    await barrier('resume_calls');
    bob = await login(1, 'bob-android');
    await checkRememberedTrust(bob);
    room = await bob.room(roomId);
    await trustPeers(bob, fresh: true);
    controller = controllerFor(bob.client);
    await report('android_devices_verified');
    final directRoomId =
        (await barrier('direct_room_created'))['room_id'] as String;
    await until(
      () async => bob.client.getRoomById(directRoomId) != null,
      'Direct invite missing',
    );
    await bob.client.getRoomById(directRoomId)!.join(waitForSync: true);
    await report('direct_room_joined');
    await until(
      () async => controller!.directInvitations.isNotEmpty,
      'Direct call did not ring',
    );
    require(
      controller.directInvitations.first.call.localUserMediaStream == null,
      'Incoming call opened microphone before acceptance',
    );
    await controller.acceptDirect(controller.directInvitations.first);
    final direct = controller.active! as DirectCall;
    await until(
      () async =>
          await direct.receivedAudioPackets() > 0 &&
          await direct.hasSecureRelay(),
      'Android TURN audio/DTLS missing',
    );
    await report('android_direct_media_passed');
    await barrier('end_direct_call');
    await controller.end();
    await report('android_direct_ended');
    await until(
      () async => controller!.invitations.isNotEmpty,
      'Android incoming call missing',
    );
    await controller.start(
      room,
      invitation: controller.invitations.values.first,
    );
    call = controller.active! as CallProbe;
    await report('android_invite_accepted');
    await until(
      () async => call!.decryptedAudioFrom.length >= 2,
      'Android did not decrypt two remote audio tracks',
    );
    await report('android_media_decrypted');
    await barrier('end_calls');
    await until(() async => call!.isClosed, 'Android call survived revocation');
    await text(room, 'after-revocation-$runId');
    await report('android_revocation_closed');
    await report('android_done');
  } finally {
    await controller?.close();
    await call?.close();
    await bob.close();
  }
}

Future<void> carol() async {
  var client = await login(2, 'carol-web');
  CallProbe? call;
  CallController? controller;
  try {
    await client.initializeRecovery(passwords[2]);
    await report('carol_ready');
    final roomId = (await barrier('room_created'))['room_id'] as String;
    await client.client.joinRoom(roomId);
    await client.room(roomId);
    await trustPeers(client);
    await barrier('close_for_recovery');
    await client.close();
    await report('carol_offline');
    await barrier('resume_calls');
    client = await login(2, 'carol-web');
    await checkRememberedTrust(client);
    await report('web_trust_persisted');
    await trustPeers(client, fresh: true);
    controller = controllerFor(client.client);
    await report('carol_devices_verified');
    await until(
      () async => controller!.invitations.isNotEmpty,
      'Carol incoming call missing',
    );
    await controller.start(
      await client.room(roomId),
      invitation: controller.invitations.values.first,
    );
    call = controller.active! as CallProbe;
    await report('carol_invite_accepted');
    await until(
      () async => call!.decryptedAudioFrom.length >= 2,
      'Carol did not decrypt two remote audio tracks',
    );
    await report('carol_media_decrypted');
    await barrier('end_calls');
    await until(() async => call!.isClosed, 'Carol call survived revocation');
    await text(await client.room(roomId), 'after-revocation-$runId');
    await report('carol_revocation_closed');
    await report('carol_done');
  } finally {
    await controller?.close();
    await call?.close();
    await client.close();
  }
}

Future<void> web() async {
  var alice = await login(0, 'alice-web');
  CallProbe? aliceCall;
  CallController? controller;
  try {
    await checkRecording();
    await report('web_recording_playback_passed');
    final recovery = await alice.initializeRecovery(passwords[0]);
    await barrier('carol_ready');
    await barrier('android_ready');
    final roomId = await alice.createRoom([userId(1), userId(2)]);
    await report('room_created', {'room_id': roomId});
    var room = await alice.room(roomId);
    await until(
      () async =>
          (await room.requestParticipants([mx.Membership.join])).length == 3,
      'Members did not join',
    );
    await alice.client.updateUserDeviceKeys(
      additionalUsers: users.map((u) => '@$u:voicechat.local').toSet(),
    );
    var unverifiedRefused = false;
    try {
      await MatrixProbe.sendText(room, 'must-not-send');
    } catch (_) {
      unverifiedRefused = true;
    }
    require(unverifiedRefused, 'Unverified devices received a send');
    final bobIdentity = await barrier('bob-android-identity');
    var mismatchRefused = false;
    try {
      await verifyDevice(
        alice.client,
        userId(1),
        bobIdentity['device_id'] as String,
        'wrong-fingerprint',
      );
    } catch (_) {
      mismatchRefused = true;
    }
    require(mismatchRefused, 'Mismatched fingerprint trusted');
    await trustPeers(alice);
    await report('device_verification_passed');
    final eventId = await MatrixProbe.sendText(room, 'web-to-android-$runId');
    final wire = await alice.client.getOneRoomEvent(roomId, eventId);
    require(
      wire.type == mx.EventTypes.Encrypted,
      'Server received plaintext event',
    );
    require(
      !jsonEncode(wire.content).contains('web-to-android-$runId'),
      'Plaintext present on wire',
    );
    await text(room, 'android-to-web-$runId');
    await report('cross_platform_text_passed', {'event_id': eventId});
    await exerciseMessages(alice, room, runId);
    await report('core_messages_passed');
    await barrier('android_attachments_passed');
    await waitCheck(
      () async => room.typingUsers.any((u) => u.id == userId(1)),
      'Typing did not arrive',
    );
    final receipts = await room.getTimeline();
    await waitCheck(
      () async => receipts.events.any(
        (e) => e.receipts.any((r) => r.user.id == userId(1)),
      ),
      'Read receipt missing',
    );
    receipts.cancelSubscriptions();
    await report('presence_receipts_passed');
    await report('close_for_recovery');
    await barrier('android_offline');
    await barrier('carol_offline');
    await alice.backup();
    final oldDevice = alice.client.deviceID!;
    final oldToken = alice.client.accessToken!;
    final oldSession =
        (await alice.client.encryption!.keyManager.loadInboundGroupSession(
          roomId,
          wire.content['session_id'] as String,
        ))!.inboundGroupSession!.exportAtFirstKnownIndex();
    await alice.close();
    alice = await login(0, 'alice-fresh-device');
    room = await alice.room(roomId);
    final before = await room.getTimeline();
    require(
      !before.events.any(
        (e) =>
            e.type == mx.EventTypes.Message &&
            e.body == 'web-to-android-$runId',
      ),
      'Fresh device unexpectedly read history',
    );
    before.cancelSubscriptions();
    var rejected = false;
    try {
      await alice.restore('invalid-recovery-key');
    } catch (_) {
      rejected = true;
    }
    require(rejected, 'Invalid recovery key accepted');
    await alice.restore(recovery);
    final restoredTimeline = await room.getTimeline();
    final encrypted = restoredTimeline.events
        .where((e) => e.type == mx.EventTypes.Encrypted)
        .toList();
    final validKeys = <bool>[];
    for (final event in encrypted) {
      final id = event.content['session_id'];
      validKeys.add(
        id is String &&
            (await alice.client.encryption!.keyManager.loadInboundGroupSession(
                  roomId,
                  id,
                ))?.isValid ==
                true,
      );
    }
    await report('restored_state', {
      'detail': jsonEncode({
        'encrypted': encrypted.length,
        'messages': restoredTimeline.events
            .where((e) => e.type == mx.EventTypes.Message)
            .length,
        'valid_keys': validKeys,
      }),
    });
    restoredTimeline.cancelSubscriptions();
    await text(room, 'web-to-android-$runId');
    await text(room, 'android-to-web-$runId');
    await checkAttachments(room);
    await report('rich_history_recovered');
    await report('history_recovered_without_old_devices');
    await trustPeers(alice, fresh: true);
    await report('resume_calls');
    await barrier('android_devices_verified');
    await barrier('carol_devices_verified');
    controller = controllerFor(alice.client);
    final directRoomId = await alice.startDirectChat(userId(1));
    final privacy = await alice.client.getRoomStateWithKey(
      directRoomId,
      'm.room.history_visibility',
      '',
    );
    require(
      privacy['history_visibility'] == 'joined',
      'Direct chat history policy is not private',
    );
    await report('direct_room_created', {'room_id': directRoomId});
    await barrier('direct_room_joined');
    await controller.start(await alice.room(directRoomId));
    final direct = controller.active! as DirectCall;
    await until(
      () async =>
          await direct.receivedAudioPackets() > 0 &&
          await direct.hasSecureRelay(),
      'Web TURN audio/DTLS missing',
    );
    await barrier('android_direct_media_passed');
    await report('direct_turn_passed');
    await report('end_direct_call');
    await controller.end();
    await barrier('android_direct_ended');
    await controller.start(room);
    aliceCall = controller.active! as CallProbe;
    await barrier('android_invite_accepted');
    await barrier('carol_invite_accepted');
    await report('foreground_invites_passed');
    await until(
      () async => aliceCall!.decryptedAudioFrom.length >= 2,
      'Web clients did not decrypt remote audio tracks',
    );
    await barrier('android_media_decrypted');
    await barrier('carol_media_decrypted');
    await report('three_participant_media_passed');
    var wrongPasswordRejected = false;
    try {
      await alice
          .revokeDevice(oldDevice, 'incorrect-test-password')
          .timeout(const Duration(seconds: 15));
    } catch (error) {
      if (error is TimeoutException) rethrow;
      wrongPasswordRejected = true;
    }
    require(wrongPasswordRejected, 'Wrong password authorized revocation');
    final stillAuthorized = await http.get(
      Uri.parse('$matrixUrl/_matrix/client/v3/account/whoami'),
      headers: {'Authorization': 'Bearer $oldToken'},
    );
    require(
      stillAuthorized.statusCode == 200,
      'Failed revocation deleted device',
    );
    await alice.revokeDevice(oldDevice, passwords[0]);
    final denied = await http.get(
      Uri.parse('$matrixUrl/_matrix/client/v3/account/whoami'),
      headers: {'Authorization': 'Bearer $oldToken'},
    );
    require(denied.statusCode == 401, 'Revoked token still works');
    final admission = await http.post(
      Uri.parse('$tokenUrl/token'),
      headers: {
        'Authorization': 'Bearer $oldToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'room_id': roomId, 'session': runId}),
    );
    require(
      admission.statusCode == 401,
      'Revoked token obtained media admission',
    );
    await until(
      () async => aliceCall!.isClosed,
      'Alice call survived revocation',
    );
    final nextId = await MatrixProbe.sendText(room, 'after-revocation-$runId');
    final next = await alice.client.getOneRoomEvent(roomId, nextId);
    require(
      next.content['session_id'] != wire.content['session_id'],
      'Megolm session reused',
    );
    var refused = false;
    final retained = vod.InboundGroupSession.import(oldSession);
    try {
      retained.decrypt(next.content['ciphertext'] as String);
    } catch (_) {
      refused = true;
    }
    require(refused, 'Retained old key decrypted post-revocation message');
    await report('revocation_verified');
    await report('end_calls');
    await barrier('android_done');
    await barrier('carol_done');
    await report('web_done');
  } finally {
    await controller?.close();
    await aliceCall?.close();
    await alice.close();
  }
}

Future<void> checkWebStorage() async {
  await checkStorageCache(runId);
  final name = 'vault-sdk-check-$runId';
  const phrase = 'separate local test phrase';
  var database = await openStore(name, passphrase: phrase);
  await database.transaction(() async {
    await database.storeClient(
      homeserverUrl: matrixUrl,
      token: 'TEST_PRIVATE_TOKEN',
      userId: '@storage:local',
      deviceId: 'STORAGE',
    );
  });
  await database.close();
  await closeStore(name);
  var rejected = false;
  try {
    await openStore(name, passphrase: 'incorrect local phrase');
  } catch (_) {
    rejected = true;
  }
  require(rejected, 'Wrong vault phrase accepted');
  database = await openStore(name, passphrase: phrase);
  require(
    (await database.getClient(name))?['token'] == 'TEST_PRIVATE_TOKEN',
    'Vault lost stored token',
  );
  await database.close();
  await closeStore(name);
  await eraseStore(name);
  await report('web_storage_roundtrip_passed');
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      theme: AppPalette.lavender.theme,
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder<String>(
            valueListenable: progress,
            builder: (_, value, child) => Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'VoiceChat · E2EE laboratory\n\n$value',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  unawaited(() async {
    try {
      require(
        runId.isNotEmpty && ['web', 'android', 'carol'].contains(role),
        'Missing disposable fixtures',
      );
      if (role == 'web') {
        await checkWebStorage();
        await web();
      } else if (role == 'carol') {
        await carol();
      } else {
        await android();
      }
    } catch (error, stack) {
      // Never send credentials, recovery keys or SDK exception payloads to logs.
      debugPrint(
        'LAB FAILED: ${error is LabFailure ? error.message : error.runtimeType}\n$stack',
      );
      await report('failed', {'detail': error.runtimeType.toString()});
    }
  }());
}
