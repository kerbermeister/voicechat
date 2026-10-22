// Disposable acceptance target; never distribute this entrypoint.
import 'dart:async';
import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:web/web.dart' as web;
import 'call_probe.dart';
import 'call_quality.dart';
import 'call_video_grid.dart';
import 'matrix_probe.dart';
import 'lab_main.dart' as lab;

final index = int.parse(Uri.base.queryParameters['peer'] ?? '-1');
CallProbe? visible;
final revision = ValueNotifier(0);

Future<void> frames(CallProbe call, int count) => lab.until(() async {
  final peers = call.media?.remoteParticipants.values.toList() ?? [];
  if (peers.length != count || call.isClosed) return false;
  for (final peer in peers) {
    final video = peer.videoTrackPublications.firstOrNull;
    if (video?.track?.receiver == null ||
        !call.decryptedVideoTracks.contains(video!.sid) ||
        !call.decryptedAudioFrom.contains(peer.identity)) {
      return false;
    }
    try {
      final stats = await video.track!.receiver!.getStats().timeout(
        const Duration(seconds: 5),
      );
      if (!stats.any(
        (s) =>
            s.type == 'inbound-rtp' &&
            (s.values['framesDecoded'] as num? ?? 0) > 3,
      )) {
        return false;
      }
    } catch (_) {
      return false;
    }
  }
  return true;
}, 'Remaining peers did not resume actual E2EE frames');

Future<void> exercise() async {
  final probe = await MatrixProbe.open(
    'revoke-${lab.runId}-$index',
    passphrase: 'disposable-revoke-vault-${lab.runId}-$index',
  );
  CallProbe? call;
  try {
    await probe.login(lab.matrixUrl, lab.users[index], lab.passwords[index]);
    await lab.report('revoke_identity_$index', {
      'user_id': probe.client.userID,
      'device_id': probe.client.deviceID,
      'fingerprint': probe.client.fingerprintKey,
    });
    if (index == 0) {
      final id = await probe.createRoom([
        lab.userId(1),
        lab.userId(2),
      ], name: 'Server revoke acceptance');
      await lab.report('revoke_room', {'room_id': id});
    }
    final roomId = (await lab.barrier('revoke_room'))['room_id'] as String;
    if (index != 0) await probe.client.joinRoom(roomId);
    for (var peer = 0; peer < 3; peer++) {
      final identity = await lab.barrier('revoke_identity_$peer');
      await verifyDevice(
        probe.client,
        identity['user_id'] as String,
        identity['device_id'] as String,
        identity['fingerprint'] as String,
      );
    }
    await lab.report('revoke_trusted_$index');
    for (var peer = 0; peer < 3; peer++) {
      await lab.barrier('revoke_trusted_$peer');
    }
    final room = await probe.room(roomId);
    call = CallProbe(
      chat: room,
      session: 'revoke${lab.runId}',
      tokenUrl: lab.tokenUrl,
      livekitUrl: lab.mediaUrl,
      status: (_) {},
      changed: () => revision.value++,
      video: true,
    )..videoQuality = VideoQuality.low;
    visible = call;
    revision.value++;
    await call.connect();
    await frames(call, 2);
    await lab.report('revoke_ready_$index');
    await lab.barrier('revoked');
    if (index != 2) {
      await frames(call, 1);
      await lab.report('revoked_frames_$index');
      await lab.barrier('replay_rejected');
      await lab.report('revoke_passed_$index');
      await lab.barrier('revoke_passed_${1 - index}');
    }
  } finally {
    await call?.close();
    await probe.close();
  }
  await lab.report('revoke_done_$index');
}

void rawPeer() {
  web.document.documentElement!.setAttribute('data-raw-ready', 'true');
  var connecting = false;
  web.window.addEventListener(
    'message',
    ((web.MessageEvent event) {
      if (event.origin != web.window.location.origin || connecting) return;
      final data = event.data.dartify();
      if (data is! Map ||
          data['type'] != 'voicechat.raw' ||
          data['token'] is! String) {
        return;
      }
      connecting = true;
      unawaited(() async {
        final room = lk.Room();
        final events = room.createListener();
        events.on<lk.RoomDisconnectedEvent>((_) {
          web.document.documentElement!.setAttribute(
            'data-raw-state',
            'disconnected',
          );
        });
        try {
          await room.connect(
            lab.mediaUrl,
            data['token'] as String,
            connectOptions: const lk.ConnectOptions(autoSubscribe: false),
          );
          web.document.documentElement!.setAttribute(
            'data-raw-state',
            'connected',
          );
        } catch (_) {
          web.document.documentElement!.setAttribute(
            'data-raw-state',
            'rejected',
          );
          await events.dispose();
          await room.dispose();
        }
      }());
    }).toJS,
  );
}

void main() {
  runApp(
    MaterialApp(
      home: Scaffold(
        body: AnimatedBuilder(
          animation: revision,
          builder: (_, _) => visible == null
              ? const Text('Acceptance fixture')
              : CallVideoGrid(call: visible!),
        ),
      ),
    ),
  );
  if (index == -1) {
    rawPeer();
    return;
  }
  unawaited(
    exercise().catchError((Object error) async {
      await lab.report('failed', {
        'detail': 'revoke peer $index: ${error.runtimeType}',
      });
    }),
  );
}
