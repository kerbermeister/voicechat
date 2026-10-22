// Ten real E2EE publishers/decoders plus one rejected peer; never distribute this target.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:http/http.dart' as http;
import 'call_probe.dart';
import 'call_quality.dart';
import 'call_video_grid.dart';
import 'matrix_probe.dart';
import 'theme.dart';
import 'lab_main.dart' as lab;
import 'lab_messaging.dart' show LabFailure;

final revision = ValueNotifier(0);
CallProbe? visible;
final index = int.parse(Uri.base.queryParameters['peer'] ?? '-1');
final accounts =
    (jsonDecode(const String.fromEnvironment('LOAD_ACCOUNTS')) as List)
        .cast<Map<String, dynamic>>();
String user(int peer) => '@${accounts[peer]['username']}:voicechat.local';

Future<void> frames(CallProbe call) async {
  await lab.until(
    () async {
      final peers = call.media?.remoteParticipants.values.toList() ?? [];
      if (peers.length != 9) return false;
      for (final peer in peers) {
        final video = peer.videoTrackPublications.firstOrNull;
        if (video?.track?.receiver == null ||
            !call.decryptedVideoTracks.contains(video!.sid) ||
            !call.decryptedAudioFrom.contains(peer.identity)) {
          return false;
        }
        final stats = await video.track!.receiver!.getStats();
        if (!stats.any(
          (s) =>
              s.type == 'inbound-rtp' &&
              (s.values['kind'] == 'video' ||
                  s.values['mediaType'] == 'video') &&
              (s.values['framesDecoded'] as num? ?? 0) > 3,
        )) {
          return false;
        }
      }
      return true;
    },
    'Nine independent E2EE video/audio streams did not decode',
    seconds: 180,
  );
}

Future<void> exercise() async {
  lab.require(
    index >= 0 && index < 11 && accounts.length == 11,
    'Eleven disposable load fixtures required',
  );
  final probe = await MatrixProbe.open(
    'load-${lab.runId}-$index',
    passphrase: 'disposable-load-vault-${lab.runId}-$index',
  );
  CallProbe? call;
  try {
    await probe.login(
      lab.matrixUrl,
      accounts[index]['username'] as String,
      accounts[index]['password'] as String,
    );
    await lab.report('load_identity_$index', {
      'user_id': probe.client.userID,
      'device_id': probe.client.deviceID,
      'fingerprint': probe.client.fingerprintKey,
    });
    if (index == 0) {
      final id = await probe.createRoom([
        for (var peer = 1; peer < 11; peer++) user(peer),
      ], name: 'E2EE admission: 10 + 1');
      await lab.report('load_room', {'room_id': id});
    }
    final id = (await lab.barrier('load_room'))['room_id'] as String;
    if (index != 0) await probe.client.joinRoom(id);
    final room = await probe.room(id);
    for (var peer = 0; peer < 11; peer++) {
      final identity = await lab.barrier('load_identity_$peer');
      await verifyDevice(
        probe.client,
        identity['user_id'] as String,
        identity['device_id'] as String,
        identity['fingerprint'] as String,
      );
    }
    await lab.report('load_trusted_$index');
    for (var peer = 0; peer < 11; peer++) {
      await lab.barrier('load_trusted_$peer');
    }
    CallProbe createCall() => CallProbe(
      chat: room,
      session: 'load${lab.runId}',
      tokenUrl: lab.tokenUrl,
      livekitUrl: lab.mediaUrl,
      video: true,
      status: (_) {},
      changed: () => revision.value++,
    )..videoQuality = VideoQuality.low;
    if (index == 10) {
      for (var peer = 0; peer < 10; peer++) {
        await lab.barrier('load_connected_$peer');
      }
      final rejected = createCall();
      var denied = false;
      try {
        await rejected.connect();
      } catch (_) {
        denied = true;
      }
      lab.require(
        denied && rejected.isClosed,
        'Eleventh participant was not rejected by the SFU',
      );
      await lab.report('load_eleventh_rejected');
      await lab.barrier('load_slot_released');
    }
    call = createCall();
    visible = call;
    revision.value++;
    await call.connect();
    await lab.report('load_connected_$index');
    await frames(call);
    await lab.report('load_frames_$index');
    if (index != 10) {
      await lab.barrier('load_eleventh_rejected');
      for (var peer = 0; peer < 10; peer++) {
        await lab.barrier('load_frames_$peer');
      }
    }
    if (index == 0) {
      await call.close();
      await lab.report('load_owner_releasing');
      for (var peer = 1; peer < 10; peer++) {
        await lab.barrier('load_owner_left_$peer');
      }
      await lab.report('load_slot_released');
    } else {
      if (index != 10) {
        await lab.barrier('load_owner_releasing');
        await lab.until(
          () async => !call!.media!.remoteParticipants.values.any(
            (p) => p.identity.startsWith('${user(0)}/'),
          ),
          'Server did not remove the disconnected participant',
        );
        await lab.report('load_owner_left_$index');
      }
      await lab.barrier('load_connected_10');
      await frames(call);
      await lab.report('load_replacement_frames_$index');
      for (var peer = 1; peer < 11; peer++) {
        await lab.barrier('load_replacement_frames_$peer');
      }
    }
    await lab.report('load_passed_$index');
    for (var peer = 0; peer < 11; peer++) {
      await lab.barrier('load_passed_$peer');
    }
  } finally {
    await call?.close();
    visible = null;
    revision.value++;
    await probe.close();
  }
  await lab.report('load_done_$index');
}

void main() {
  runApp(
    MaterialApp(
      theme: AppPalette.lavender.theme,
      home: Scaffold(
        body: SafeArea(
          child: AnimatedBuilder(
            animation: Listenable.merge([lab.progress, revision]),
            builder: (_, _) => Column(
              children: [
                Text(lab.progress.value),
                if (visible != null && !visible!.isClosed)
                  Expanded(child: CallVideoGrid(call: visible!)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  unawaited(
    exercise().catchError((Object error, StackTrace stack) async {
      debugPrint(
        'LOAD STACK: ${stack.toString().split('\n').take(10).join('\n')}',
      );
      final kind = switch (error) {
        http.ClientException(:final uri) =>
          'http_${uri?.host}:${uri?.port}${uri?.path}',
        lk.ConnectException(:final reason, :final statusCode) =>
          'livekit_connect_${reason.name}_$statusCode',
        lk.TimeoutException() => 'livekit_timeout',
        lk.MediaConnectException() => 'livekit_media_connect',
        lk.LiveKitE2EEException() => 'livekit_e2ee',
        _ => error.runtimeType.toString(),
      };
      await lab.report('failed', {
        'detail':
            'peer $index: ${error is LabFailure
                ? error.message
                : error is StateError
                ? error.message
                : kind}',
      });
    }),
  );
}
