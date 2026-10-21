// Separate entrypoint: fixtures are disposable and must never ship in the app.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as mx;
import 'package:vodozemac/vodozemac.dart' as vod;
import 'matrix_probe.dart';
import 'call_probe.dart';
import 'theme.dart';

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
  if (!condition) throw StateError(message);
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
  throw TimeoutException(failure);
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
  final probe = await MatrixProbe.open('$runId-$profile', laboratory: true);
  await probe.login(matrixUrl, users[index], passwords[index]);
  return probe;
}

Future<mx.Event> text(mx.Room room, String body) async {
  final timeline = await room.getTimeline();
  mx.Event? found;
  try {
    await until(() async {
      for (final event in timeline.events) {
        if (event.type == mx.EventTypes.Message && event.body == body) {
          found = event;
          return true;
        }
      }
      return false;
    }, 'Message did not decrypt: $body');
    return found!;
  } finally {
    timeline.cancelSubscriptions();
  }
}

CallProbe callFor(mx.Room room) => CallProbe(
  chat: room,
  session: runId,
  tokenUrl: tokenUrl,
  livekitUrl: mediaUrl,
  status: (value) => progress.value = value,
);

Future<void> android() async {
  var bob = await login(1, 'bob-android');
  CallProbe? call;
  try {
    await bob.initializeRecovery(passwords[1]);
    await report('android_ready');
    final roomId = (await barrier('room_created'))['room_id'] as String;
    await bob.client.joinRoom(roomId);
    var room = await bob.room(roomId);
    await text(room, 'web-to-android-$runId');
    await MatrixProbe.sendText(room, 'android-to-web-$runId');
    await bob.backup();
    await report('android_message_decrypted');
    await barrier('close_for_recovery');
    await bob.close();
    await report('android_offline');
    await barrier('resume_calls');
    bob = await login(1, 'bob-android');
    room = await bob.room(roomId);
    call = callFor(room);
    await call.connect();
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
    await call?.close();
    await bob.close();
  }
}

Future<void> carol() async {
  var client = await login(2, 'carol-web');
  CallProbe? call;
  try {
    await client.initializeRecovery(passwords[2]);
    await report('carol_ready');
    final roomId = (await barrier('room_created'))['room_id'] as String;
    await client.client.joinRoom(roomId);
    await client.room(roomId);
    await barrier('close_for_recovery');
    await client.close();
    await report('carol_offline');
    await barrier('resume_calls');
    client = await login(2, 'carol-web');
    call = callFor(await client.room(roomId));
    await call.connect();
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
    await call?.close();
    await client.close();
  }
}

Future<void> web() async {
  var alice = await login(0, 'alice-web');
  CallProbe? aliceCall;
  try {
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
    await text(room, 'web-to-android-$runId');
    await text(room, 'android-to-web-$runId');
    await report('history_recovered_without_old_devices');
    await report('resume_calls');
    aliceCall = callFor(room);
    await aliceCall.connect();
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
    await aliceCall?.close();
    await alice.close();
  }
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
        await web();
      } else if (role == 'carol') {
        await carol();
      } else {
        await android();
      }
    } catch (error, stack) {
      // Never send credentials, recovery keys or SDK exception payloads to logs.
      debugPrint('LAB FAILED: ${error.runtimeType}\n$stack');
      await report('failed', {'detail': error.runtimeType.toString()});
    }
  }());
}
