// Test-only bridge for synthetic markers through the pinned LiveKit SDK and SFU.
// ignore_for_file: invalid_use_of_internal_member
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamWeb;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:web/web.dart' as web;

import 'package:voicechat_probe/call_video_playout_web.dart';

lk.Room? publisher, subscriber;
lk.BaseKeyProvider? sendKeys, receiveKeys;
String stage = "idle";
final missingKeyStats = <String, Object>{};
bool missingKeyBlocked = false;
bool? sharedSyncGroup;

Future<web.MediaStream> connect(web.MediaStream input, bool split) async {
  final response = await web.window.fetch('/probe.json'.toJS).toDart;
  if (!response.ok) throw StateError('Missing loopback SFU config');
  final config = jsonDecode((await response.text().toDart).toDart) as Map;
  final random = Random.secure();
  final key = Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
  final outgoing = sendKeys = await lk.BaseKeyProvider.create(
    sharedKey: false,
    discardFrameWhenCryptorNotReady: true,
  );
  final incoming = receiveKeys = await lk.BaseKeyProvider.create(
    sharedKey: false,
    discardFrameWhenCryptorNotReady: true,
  );
  await outgoing.setRawKey(key, participantId: 'alice');
  final alice = publisher = lk.Room(
    roomOptions: lk.RoomOptions(
      encryption: lk.E2EEOptions(keyProvider: outgoing),
    ),
  );
  final bob = subscriber = lk.Room(
    roomOptions: lk.RoomOptions(
      encryption: lk.E2EEOptions(keyProvider: incoming),
    ),
  );
  stage = 'connect';
  await bob.connect(config['url'], config['bob']);
  await alice.connect(config['url'], config['alice']);
  final stream = MediaStreamWeb(input, 'local');
  final participant = alice.localParticipant!;
  stage = 'publish audio';
  await participant.publishAudioTrack(
    lk.LocalAudioTrack(
      lk.TrackSource.microphone,
      stream,
      stream.getAudioTracks().single,
      const lk.AudioCaptureOptions(),
    ),
    publishOptions: lk.AudioPublishOptions(
      stream: 'marker-av',
      dtx: !Uri.base.queryParameters.containsKey('continuous_opus'),
    ),
  );
  stage = 'publish video';
  await participant.publishVideoTrack(
    lk.LocalVideoTrack(
      lk.TrackSource.camera,
      stream,
      stream.getVideoTracks().single,
      const lk.CameraCaptureOptions(),
    ),
    publishOptions: lk.VideoPublishOptions(
      stream: split ? 'marker-video' : 'marker-av',
      simulcast: false,
      videoCodec: 'vp8',
    ),
  );
  stage = 'subscriptions';
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 15)) {
    final remote = bob.remoteParticipants['alice'];
    final audio = remote?.audioTrackPublications.firstOrNull?.track;
    final publication = remote?.videoTrackPublications.firstOrNull;
    final video = publication?.track;
    if (audio != null && video != null) {
      stage = 'grouping';
      final audioStream = (audio.mediaStream as MediaStreamWeb).jsStream;
      final videoStream = (video.mediaStream as MediaStreamWeb).jsStream;
      sharedSyncGroup = audioStream.id == videoStream.id;
      if (split && sharedSyncGroup!) {
        throw StateError('Expected separate SFU stream groups');
      }
      final tracks = web.MediaStream();
      tracks.addTrack(audioStream.getAudioTracks().toDart.single);
      tracks.addTrack(videoStream.getVideoTracks().toDart.single);
      stage = 'missing-key counters';
      await Future<void>.delayed(const Duration(seconds: 3));
      for (final (label, track) in [('audio', audio), ('video', video)]) {
        final stats = await track.receiver!.getStats();
        final report = stats
            .where((row) => row.type == 'inbound-rtp')
            .firstOrNull;
        final values = report?.values ?? {};
        final packets = (values['packetsReceived'] as num?) ?? 0;
        final decoded = label == 'audio'
            ? ((values['totalSamplesReceived'] as num?) ?? 0) -
                  ((values['concealedSamples'] as num?) ?? 0)
            : ((values['framesDecoded'] as num?) ?? 0);
        missingKeyStats[label] = [packets, decoded];
      }
      if (missingKeyStats.values.any((row) {
        final counters = row as List<num>;
        return counters.first == 0 || counters.last > 0;
      })) {
        throw StateError('Missing-key media gate failed');
      }
      missingKeyBlocked = true;
      stage = 'install receive key';
      await incoming.setRawKey(key, participantId: 'alice');
      stage = 'connected';
      return tracks;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('SFU did not subscribe both tracks');
}

Future<void> dispose() async {
  await publisher?.dispose();
  await subscriber?.dispose();
  await sendKeys?.keyProvider.dispose();
  await receiveKeys?.keyProvider.dispose();
}

void main() {
  if (web.window.location.hostname != '127.0.0.1') {
    throw StateError('Loopback fixture required');
  }
  web.window.setProperty(
    'VoiceChatMarkerSfu'.toJS,
    {
      'connect': ((web.MediaStream stream, JSBoolean split) => connect(
        stream,
        split.toDart,
      ).then<JSAny?>((media) => media).toJS).toJS,
      'diagnostics': (() => {
        'stage': stage,
        'shared_stream_group': sharedSyncGroup,
        'without_key': missingKeyStats,
      }.jsify()).toJS,
      'applyVideoTarget': ((
        web.RTCRtpReceiver receiver,
      ) => applyCallVideoPlayoutTarget(receiver)).toJS,
      'missingKeyBlocked': (() => missingKeyBlocked.toJS).toJS,
      'dispose': (() => dispose().toJS).toJS,
    }.jsify(),
  );
}
