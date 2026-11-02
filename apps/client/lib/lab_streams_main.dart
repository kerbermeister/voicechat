// Local integration entrypoint; never ship this target as the ordinary client.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'matrix_probe.dart';
import 'stream_controller.dart';

const runId = String.fromEnvironment('RUN_ID');
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
const alice = String.fromEnvironment('ALICE_USER');
const bob = String.fromEnvironment('BOB_USER');
const alicePassword = String.fromEnvironment('ALICE_PASSWORD');
const bobPassword = String.fromEnvironment('BOB_PASSWORD');
final role =
    Uri.base.queryParameters['role'] ??
    const String.fromEnvironment('STREAM_ROLE', defaultValue: 'owner');
final progress = ValueNotifier('starting');
final current = ValueNotifier<LiveStreamController?>(null);

void require(bool value, String reason) {
  if (!value) throw StateError(reason);
}

Future<void> report(
  String stage, [
  Map<String, dynamic> body = const {},
]) async {
  progress.value = '$role:$stage';
  final response = await http.post(
    Uri.parse('$tokenUrl/report'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'run': runId,
      'role': 'stream-$role',
      'stage': stage,
      'detail': jsonEncode(body),
    }),
  );
  require(response.statusCode == 200, 'report unavailable');
}

Future<Map<String, dynamic>> barrier(String side, String stage) async {
  Map<String, dynamic>? found;
  await until(() async {
    final response = await http.get(Uri.parse('$tokenUrl/reports'));
    final list = jsonDecode(response.body) as List;
    final matching = list.where(
      (v) =>
          v['run'] == runId &&
          v['role'] == 'stream-$side' &&
          v['stage'] == stage,
    );
    if (matching.isNotEmpty)
      found = Map<String, dynamic>.from(matching.last as Map);
    return found != null;
  }, '$side:$stage');
  return {
    ...found!,
    ...jsonDecode(found!['detail'] as String) as Map<String, dynamic>,
  };
}

Future<void> until(
  Future<bool> Function() predicate,
  String reason, {
  int seconds = 90,
}) async {
  final timer = Stopwatch()..start();
  while (timer.elapsed < Duration(seconds: seconds)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw StateError(reason);
}

Future<bool> decodedVideo(LiveStreamController controller) async {
  for (final participant
      in controller.media?.remoteParticipants.values ??
          <lk.RemoteParticipant>[]) {
    for (final publication in participant.videoTrackPublications) {
      if (!controller.decryptedVideo.contains(publication.sid)) continue;
      final reports = await publication.track?.receiver?.getStats();
      for (final report in reports ?? []) {
        if ((report.values['framesDecoded'] as num? ?? 0) > 0) return true;
      }
    }
  }
  return false;
}

Future<void> exercise() async {
  await report('opening');
  final owner = role == 'owner';
  final probe = await MatrixProbe.open(
    'stream-lab-$runId-$role',
    passphrase: 'lab-$runId-$role',
  ).timeout(const Duration(seconds: 45));
  await report('opened');
  await probe.login(
    matrixUrl,
    owner ? alice : bob,
    owner ? alicePassword : bobPassword,
  );
  final client = probe.client;
  await report('identity', {
    'user': client.userID,
    'device': client.deviceID,
    'fingerprint': client.fingerprintKey,
  });
  final other = await barrier(owner ? 'viewer' : 'owner', 'identity');
  await verifyDevice(
    client,
    other['user'] as String,
    other['device'] as String,
    other['fingerprint'] as String,
  );
  final stream = LiveStreamController(client, tokenUrl, mediaUrl);
  current.value = stream;
  await stream.open();
  require(stream.available, 'stream capabilities');
  try {
    if (owner) {
      await stream.start({
        'title': 'Local E2EE camera stream',
        'description': 'ephemeral test',
        'audience': [other['user']],
        'comments': true,
        'duration': 240,
      });
      await stream.sendComment('before viewer joined');
      await report('started', {'stream': stream.snapshot!.id});
      await barrier('viewer', 'watching');
      await until(
        () async => stream.comments.any((m) => m.text == 'viewer reply'),
        'viewer signed reply',
      );
      final replayCache = await client.database.getLastSentMessageUserDeviceKey(
        other['user'] as String,
        other['device'] as String,
      );
      require(
        replayCache == null ||
            !replayCache.any((v) => v.contains('dev.voicechat.stream.keys')),
        'plaintext key replay cache',
      );
      await stream.camera(false);
      require(
        stream.microphoneOn &&
            stream.media!.localParticipant!.audioTrackPublications.isNotEmpty,
        'audio remains without camera',
      );
      await report('camera-off');
      await barrier('viewer', 'camera-off-seen');
      await stream.camera(true);
      await stream.pauseForCall();
      await report('paused');
      await barrier('viewer', 'paused-seen');
      await until(
        () async => stream.comments.any((m) => m.text == 'chat during pause'),
        'paused chat',
      );
      await stream.resume();
      await report('resumed');
      await barrier('viewer', 'resumed-seen');
      await stream.leave();
      await report('complete', {'key_cache_clean': true});
    } else {
      final started = await barrier('owner', 'started');
      await stream.join(started['stream'] as String);
      await until(() => decodedVideo(stream), 'decrypted decoded video');
      await until(
        () async =>
            stream.comments.any((m) => m.text == 'before viewer joined'),
        'full late history',
      );
      await stream.sendComment('viewer reply');
      await report('watching', {'decoded_video': true, 'late_history': true});
      await barrier('owner', 'camera-off');
      await until(
        () async =>
            stream.media?.remoteParticipants.values.every(
              (p) => p.videoTrackPublications.every(
                (t) => t.muted || t.track == null,
              ),
            ) ??
            false,
        'camera removed',
      );
      await report('camera-off-seen');
      await barrier('owner', 'paused');
      await until(
        () async => stream.snapshot?.state == 'paused' && stream.media == null,
        'pause closes media',
      );
      await stream.sendComment('chat during pause');
      await report('paused-seen');
      await barrier('owner', 'resumed');
      await until(
        () => decodedVideo(stream),
        'decrypted video after manual resume',
      );
      await report('resumed-seen');
      await barrier('owner', 'complete');
      await until(
        () async => !stream.active && stream.comments.isEmpty,
        'end clears chat',
      );
      await report('complete', {
        'media_stopped': stream.media == null,
        'chat_cleared': true,
      });
    }
  } finally {
    await stream.close();
    await probe.close();
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            ValueListenableBuilder(
              valueListenable: progress,
              builder: (_, value, _) => Text(value),
            ),
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: current,
                builder: (_, controller, _) => controller == null
                    ? const SizedBox()
                    : AnimatedBuilder(
                        animation: controller,
                        builder: (_, _) {
                          final tracks = <lk.VideoTrack>[
                            for (final p
                                in controller
                                        .media
                                        ?.remoteParticipants
                                        .values ??
                                    <lk.RemoteParticipant>[])
                              for (final t in p.videoTrackPublications)
                                if (t.track is lk.VideoTrack) t.track!,
                          ];
                          return Column(
                            children: [
                              Text(controller.status),
                              if (tracks.isNotEmpty)
                                Expanded(
                                  child: lk.VideoTrackRenderer(tracks.first),
                                ),
                            ],
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  unawaited(() async {
    try {
      await exercise();
    } catch (error, stack) {
      debugPrint('STREAM LAB ${error.runtimeType}\n$stack');
      await report('failed', {
        'type': error.runtimeType.toString(),
        'reason': error is StateError ? error.message : 'integration failure',
      });
    }
  }());
}
