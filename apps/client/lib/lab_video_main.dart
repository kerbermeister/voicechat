// Disposable cross-platform acceptance; never build this entrypoint for distribution.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'call_controller.dart';
import 'call_probe.dart';
import 'call_quality.dart';
import 'call_video_grid.dart';
import 'direct_call.dart';
import 'voice_call.dart';
import 'lab_main.dart' as lab;
import 'lab_messaging.dart' show LabFailure;
import 'theme.dart';
import 'lab_verification.dart';

VoiceCall? visibleCall;
final revision = ValueNotifier(0);
final navigatorKey = GlobalKey<NavigatorState>();
SemanticsHandle? probeSemantics;
void redraw() => revision.value++;

bool decoded(List<rtc.StatsReport> reports, {bool low = false}) => reports.any(
  (s) =>
      s.type == 'inbound-rtp' &&
      (s.values['kind'] == 'video' || s.values['mediaType'] == 'video') &&
      (s.values['framesDecoded'] as num? ?? 0) > 5 &&
      (!low ||
          (s.values['frameWidth'] as num? ?? 10000) <= 320 &&
              (s.values['frameHeight'] as num? ?? 10000) <= 180),
);

Future<void> checkDirect(DirectCall call) async {
  Future<void> diagnostics() async {
    try {
      final stats = await call.call.pc?.getStats() ?? [];
      await lab.report('video_direct_diagnostics', {
        'detail': jsonEncode({
          'state': call.call.state.name,
          'local_width': call.localVideo?.videoWidth,
          'remote_width': call.remoteVideo?.videoWidth,
          'relay': await call.hasSecureRelay(),
          'audio_packets': await call.receivedAudioPackets(),
          'video': [
            for (final stat in stats.where(
              (s) =>
                  s.type == 'inbound-rtp' &&
                  (s.values['kind'] == 'video' ||
                      s.values['mediaType'] == 'video'),
            ))
              {
                'frames': stat.values['framesDecoded'],
                'packets': stat.values['packetsReceived'],
              },
          ],
        }),
      });
    } catch (_) {
      /* Diagnostics must not interrupt the media assertion. */
    }
  }

  final timer = Timer.periodic(
    const Duration(seconds: 5),
    (_) => unawaited(diagnostics()),
  );
  try {
    await lab.until(
      () async =>
          call.remoteVideo != null &&
          call.remoteVideo!.videoWidth > 0 &&
          call.localVideo != null &&
          call.localVideo!.videoWidth > 0 &&
          call.call.localUserMediaStream!.stream!.getAudioTracks().every(
            (track) => track.enabled,
          ) &&
          decoded(await call.call.pc!.getStats()) &&
          await call.hasSecureRelay() &&
          await call.receivedAudioPackets() > 0,
      'Direct video/audio or secure TURN did not arrive',
    );
  } finally {
    timer.cancel();
    await diagnostics();
  }
}

Future<void> checkGroup(CallProbe call) async {
  await lab.until(() async {
    final participants = call.media?.remoteParticipants.values.toList() ?? [];
    if (participants.length != 2 || call.decryptedAudioFrom.length != 2) {
      return false;
    }
    for (final participant in participants) {
      final video = participant.videoTrackPublications.firstOrNull;
      if (video == null || !call.decryptedVideoTracks.contains(video.sid)) {
        return false;
      }
      final receiver = video.track?.receiver;
      if (receiver == null || !decoded(await receiver.getStats())) return false;
    }
    return true;
  }, 'Two independent E2EE video decoders did not produce frames');
}

Future<void> checkBackground(CallProbe call, int index) async {
  Future<int> audioPackets(String identity) async {
    final publication = call.media!.remoteParticipants.values
        .where((p) => p.identity.startsWith('$identity/'))
        .single
        .audioTrackPublications
        .single;
    final reports = await publication.track!.receiver!.getStats();
    return reports
        .where((s) => s.type == 'inbound-rtp')
        .fold<int>(
          0,
          (sum, s) =>
              sum + ((s.values['packetsReceived'] as num?)?.toInt() ?? 0),
        );
  }

  if (index == 1) await lab.report('video_background_ready');
  await lab.barrier('video_background_ready');
  if (index == 1) {
    await lab.until(
      () async =>
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed &&
          !call.cameraEnabled,
      'Background camera did not stop',
    );
    lab.require(
      call.media!.localParticipant!.audioTrackPublications.single.track != null,
      'Background lost the local microphone',
    );
  } else {
    await lab.until(
      () async => call.media!.remoteParticipants.values
          .where((p) => p.identity.startsWith('${lab.userId(1)}/'))
          .single
          .videoTrackPublications
          .isEmpty,
      'Android background camera stayed published',
    );
  }
  final sender = lab.userId(index == 1 ? 0 : 1);
  final before = await audioPackets(sender);
  await Future<void>.delayed(const Duration(seconds: 3));
  lab.require(
    await audioPackets(sender) > before + 10,
    'Background audio packets stopped',
  );
  await lab.report('video_background_audio_$index');
  for (var peer = 0; peer < 3; peer++) {
    await lab.barrier('video_background_audio_$peer');
  }
  if (index == 1) {
    await lab.until(
      () async =>
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          call.cameraEnabled,
      'Returning to the preserved call did not restart the camera',
    );
    await lab.report('video_background_returned');
  }
  await lab.barrier('video_background_returned');
  await checkGroup(call);
}

Future<void> exercise() async {
  final index = lab.role == 'android'
      ? 1
      : lab.role == 'carol'
      ? 2
      : 0;
  final profile = ['alice-web', 'bob-android', 'carol-web'][index];
  final probe = await lab.login(index, profile);
  final calls = CallController(
    probe.client,
    lab.tokenUrl,
    lab.mediaUrl,
    (s) => lab.progress.value = s,
  );
  calls.addListener(() {
    visibleCall = calls.active;
    redraw();
  });
  try {
    if (index == 0) {
      final room = await probe.createRoom([
        lab.userId(1),
        lab.userId(2),
      ], name: 'Видео Android ↔ Web');
      await lab.report('video_room_created', {'room_id': room});
    }
    final groupId =
        (await lab.barrier('video_room_created'))['room_id'] as String;
    if (index != 0) await probe.client.joinRoom(groupId);
    final groupRoom = await probe.room(groupId);
    await lab.until(
      () async {
        try {
          await lab.trustPeers(probe);
          return true;
        } catch (_) {
          return false;
        }
      },
      'Fixture device keys were not published',
      seconds: 30,
    );
    await lab.report('video_joined_$index');
    for (var peer = 0; peer < 3; peer++) {
      await lab.barrier('video_joined_$peer');
    }
    if (const bool.fromEnvironment('VERIFY_TEST')) {
      await verifyLabDevices(probe, index, navigatorKey.currentContext!);
    }
    if (index == 0) {
      final roomId = await probe.startDirectChat(lab.userId(1));
      await lab.report('video_direct_room', {'room_id': roomId});
      await lab.barrier('video_direct_joined');
      await calls.start(await probe.room(roomId), video: true);
    } else if (index == 1) {
      final roomId =
          (await lab.barrier('video_direct_room'))['room_id'] as String;
      await lab.until(
        () async => probe.client.getRoomById(roomId) != null,
        'Direct invite did not arrive',
      );
      await probe.client.getRoomById(roomId)!.join(waitForSync: true);
      await lab.report('video_direct_joined');
      await lab.until(
        () async => calls.directInvitations.isNotEmpty,
        'Video offer did not ring',
      );
      final invitation = calls.directInvitations.first;
      lab.require(
        invitation.video && invitation.call.localUserMediaStream == null,
        'Incoming offer opened the camera before acceptance',
      );
      await calls.acceptDirect(invitation);
    }
    if (index != 2) {
      await checkDirect(calls.active! as DirectCall);
      await lab.report('video_direct_frames_$index');
    }
    if (index == 0) {
      await lab.barrier('video_direct_frames_1');
      await calls.end();
      await lab.report('video_direct_ended');
    } else if (index == 1) {
      await lab.until(
        () async => calls.active!.isClosed,
        'Remote hangup did not close Android camera',
      );
    }
    await lab.barrier('video_direct_ended');
    if (index == 0) {
      await calls.start(groupRoom, video: true);
    } else {
      await lab.until(
        () async => calls.invitations.isNotEmpty,
        'Group video invitation missing',
      );
      final invitation = calls.invitations.values.first;
      lab.require(invitation.video, 'Video invitation lost its media mode');
      await calls.start(groupRoom, invitation: invitation);
    }
    final call = calls.active! as CallProbe;
    await checkGroup(call);
    await lab.report('video_group_frames_$index');
    for (var peer = 0; peer < 3; peer++) {
      await lab.barrier('video_group_frames_$peer');
    }
    if (const bool.fromEnvironment('BACKGROUND_TEST')) {
      await checkBackground(call, index);
    }
    if (index == 1) {
      await call.switchCamera();
      await call.camera(false);
      lab.require(
        call.media!.localParticipant!.videoTrackPublications.isEmpty,
        'Camera-off retained its publication',
      );
      await call.camera(true);
      await lab.report('video_android_camera_switched');
    }
    await lab.barrier('video_android_camera_switched');
    await checkGroup(call);
    await lab.report('video_camera_frames_$index');
    if (index == 0) {
      for (var peer = 0; peer < 3; peer++) {
        await lab.barrier('video_camera_frames_$peer');
      }
      await call.setVideoQuality(VideoQuality.low);
      await lab.report('video_low_selected');
      await lab.barrier('video_low_decoded_android');
      await call.setVideoQuality(VideoQuality.auto);
      await lab.report('video_auto_restored');
    } else if (index == 1) {
      await lab.barrier('video_low_selected');
      await lab.until(() async {
        final alice = call.media!.remoteParticipants.values
            .where((p) => p.identity.startsWith('${lab.userId(0)}/'))
            .single;
        final publication = alice.videoTrackPublications.firstOrNull;
        return publication?.track?.receiver != null &&
            call.decryptedVideoTracks.contains(publication!.sid) &&
            decoded(await publication.track!.receiver!.getStats(), low: true);
      }, 'Android did not decode the bounded 180p stream');
      await lab.report('video_low_decoded_android');
    }
    await lab.barrier('video_auto_restored');
    await checkGroup(call);
    await lab.report('video_passed_$index');
    for (var peer = 0; peer < 3; peer++) {
      await lab.barrier('video_passed_$peer');
    }
    await calls.end();
    await lab.report('video_done_$index');
  } finally {
    await calls.close();
    visibleCall = null;
    redraw();
    await probe.close();
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('VERIFY_TEST')) {
    probeSemantics = SemanticsBinding.instance.ensureSemantics();
  }
  runApp(
    MaterialApp(
      navigatorKey: navigatorKey,
      theme: AppPalette.lavender.theme,
      home: Scaffold(
        body: SafeArea(
          child: AnimatedBuilder(
            animation: Listenable.merge([lab.progress, revision]),
            builder: (_, _) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(lab.progress.value),
                ),
                if (visibleCall != null && !visibleCall!.isClosed)
                  Expanded(child: CallVideoGrid(call: visibleCall!)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  unawaited(
    exercise().catchError((Object error) async {
      final detail = error is LabFailure
          ? error.message.toString()
          : error.runtimeType.toString();
      debugPrint('VIDEO FAILED: $detail');
      await lab.report('failed', {'detail': detail});
    }),
  );
}
