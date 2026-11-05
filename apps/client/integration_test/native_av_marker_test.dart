// Real native SDK/SFU media; synthetic tones and bitmaps, no account or camera.
// ignore_for_file: invalid_use_of_internal_member
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:integration_test/integration_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

Future<void> labPost(String suffix, Object value) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('${const String.fromEnvironment('AV_MARKER_OUTPUT')}$suffix'),
    );
    final bytes = utf8.encode(jsonEncode(value));
    request.contentLength = bytes.length;
    for (var offset = 0; offset < bytes.length; offset += 65536) {
      request.add(
        Uint8List.sublistView(bytes, offset, min(offset + 65536, bytes.length)),
      );
      await request.flush();
    }
    final reply = await request.close();
    expect(reply.statusCode, 200);
    await reply.drain<void>();
  } finally {
    client.close(force: true);
  }
}

Future<void> labWait(String state) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 180)) {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('${const String.fromEnvironment('AV_MARKER_OUTPUT')}/state'),
      );
      final reply = await request.close();
      expect(reply.statusCode, 200);
      final value = jsonDecode(await utf8.decoder.bind(reply).join()) as Map;
      if (value[state] == true) return;
    } finally {
      client.close(force: true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  fail('Separate native peer did not reach $state');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native encrypted audio/video marker playout', (tester) async {
    const channel = MethodChannel('voicechat/native-av-lab');
    const nativePlayout = int.fromEnvironment('AV_NATIVE_VIDEO_PLAYOUT_MS');
    const fullReset = bool.fromEnvironment('AV_TIMESTAMP_FULL_RESET');
    if (fullReset) {
      expect(nativePlayout, 0);
      await channel.invokeMethod<void>('timestampReset', {
        'milliseconds': 0,
        'fullReset': true,
      });
    }
    if (nativePlayout != 0) {
      await channel.invokeMethod<void>('playout', {
        'milliseconds': nativePlayout,
        'minimum': const int.fromEnvironment(
          'AV_NATIVE_VIDEO_MIN_PLAYOUT_MS',
          defaultValue: nativePlayout,
        ),
      });
    }
    final random = Random.secure();
    const role = String.fromEnvironment('AV_MARKER_ROLE', defaultValue: 'both');
    const encodedKey = String.fromEnvironment('AV_MARKER_KEY');
    final key = encodedKey.isNotEmpty
        ? base64Decode(encodedKey)
        : Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
    expect(key.length, 32);
    expect({'both', 'sender', 'receiver'}, contains(role));
    final sendKeys = await lk.BaseKeyProvider.create(sharedKey: false);
    final receiveKeys = await lk.BaseKeyProvider.create(sharedKey: false);
    await sendKeys.setRawKey(key, participantId: 'alice');
    final alice = lk.Room(
      roomOptions: lk.RoomOptions(
        encryption: lk.E2EEOptions(keyProvider: sendKeys),
      ),
    );
    final options = lk.RoomOptions(
      encryption: lk.E2EEOptions(keyProvider: receiveKeys),
    );
    final bob = lk.Room(roomOptions: options);
    rtc.MediaStream? stream;
    try {
      const url = String.fromEnvironment('GROUP_TEST_URL');
      if (role != 'sender') {
        await bob.connect(url, const String.fromEnvironment('GROUP_TEST_BOB'));
        if (role == 'receiver') {
          await channel.invokeMethod<void>('receive');
          await labPost('/ready', {'receiver_ready': true});
        }
      }
      if (role != 'receiver') {
        await alice.connect(
          url,
          const String.fromEnvironment('GROUP_TEST_ALICE'),
        );
        if (role == 'sender') await labWait('receiver_ready');
        stream = await rtc.navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': false,
        });
        await channel.invokeMethod<void>('create', {
          'stream': stream.id,
          'coherent': const bool.fromEnvironment('AV_COHERENT_MARKERS'),
          'speech': base64Decode(
            const String.fromEnvironment('AV_SPEECH_BASE64'),
          ),
        });
        // ignore: deprecated_member_use
        await stream.getMediaTracks();
        final localAudio = lk.LocalAudioTrack(
          lk.TrackSource.microphone,
          stream,
          stream.getAudioTracks().single,
          const lk.AudioCaptureOptions(),
        );
        final localVideo = lk.LocalVideoTrack(
          lk.TrackSource.camera,
          stream,
          stream.getVideoTracks().single,
          const lk.CameraCaptureOptions(),
        );
        final a = await alice.localParticipant!.publishAudioTrack(
          localAudio,
          publishOptions: const lk.AudioPublishOptions(stream: 'marker-av'),
        );
        final v = await alice.localParticipant!.publishVideoTrack(
          localVideo,
          publishOptions: const lk.VideoPublishOptions(
            stream: 'marker-av',
            simulcast: false,
            videoCodec: 'vp8',
            videoEncoding: lk.VideoEncoding(
              maxBitrate: 500000,
              maxFramerate: 20,
            ),
          ),
        );
        expect(a.encryptionType, lk.EncryptionType.kGcm);
        expect(v.encryptionType, lk.EncryptionType.kGcm);
        if (role == 'sender') {
          await labWait('receiver_done');
          final markers = await channel.invokeMapMethod<String, dynamic>(
            'result',
          );
          await labPost('/source', {
            'source_audio': markers!['source_audio'],
            'source_video': markers['source_video'],
            'encrypted_publications': true,
            'synthetic_media_only': true,
            'coherent_source': const bool.fromEnvironment(
              'AV_COHERENT_MARKERS',
            ),
            'native_video_playout_ms': nativePlayout,
            'native_video_min_playout_ms': const int.fromEnvironment(
              'AV_NATIVE_VIDEO_MIN_PLAYOUT_MS',
              defaultValue: nativePlayout,
            ),
          });
          return;
        }
      }
      final watch = Stopwatch()..start();
      lk.RemoteAudioTrack? audio;
      lk.RemoteVideoTrack? video;
      while (watch.elapsed < const Duration(seconds: 90)) {
        final participant = bob.remoteParticipants['alice'];
        audio = participant?.audioTrackPublications.firstOrNull?.track;
        video = participant?.videoTrackPublications.firstOrNull?.track;
        if (audio != null && video != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(audio, isNotNull);
      expect(video, isNotNull);
      await channel.invokeMethod<void>('observe', {
        'audio': audio!.mediaStreamTrack.id,
        'video': video!.mediaStreamTrack.id,
      });
      await Future<void>.delayed(const Duration(seconds: 3));
      final gate = <String, Object>{};
      final contentGate = await channel.invokeMapMethod<String, dynamic>(
        'gate',
      );
      expect(contentGate!['video_markers'], 0);
      expect(contentGate['audio_peak'], lessThan(.001));
      gate['content'] = contentGate;
      for (final (label, track) in [('audio', audio), ('video', video)]) {
        final reports = await track.receiver!.getStats();
        final stats = reports
            .where((row) => row.type == 'inbound-rtp')
            .first
            .values;
        final decoded = label == 'video'
            ? (stats['framesDecoded'] as num? ?? 0)
            : (stats['totalSamplesReceived'] as num? ?? 0) -
                  (stats['concealedSamples'] as num? ?? 0);
        expect(stats['packetsReceived'], greaterThan(0));
        if (label == 'video') expect(decoded, 0);
        gate[label] = {'packets': stats['packetsReceived'], 'decoded': decoded};
      }
      await receiveKeys.setRawKey(key, participantId: 'alice');
      final samples = <Object>[];
      final phases = <Object>[];
      const network = bool.fromEnvironment('AV_MARKER_NETWORK');
      final payloads = <int>{};
      for (var attempt = 0; attempt < 50 && payloads.isEmpty; attempt++) {
        final reports = await bob.engine.subscriber!.pc.getStats();
        for (final row in reports) {
          if (row.type == 'codec' &&
              {
                'video/vp8',
                'video/rtx',
              }.contains((row.values['mimeType'] as String?)?.toLowerCase())) {
            payloads.add((row.values['payloadType'] as num).toInt());
          }
        }
        if (payloads.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      final remoteSdp =
          (await bob.engine.subscriber!.pc.getRemoteDescription())!.sdp!;
      final answerSdp =
          (await bob.engine.subscriber!.pc.getLocalDescription())!.sdp!;
      final playoutNegotiated =
          remoteSdp.contains('rtp-hdrext/playout-delay') &&
          answerSdp.contains('rtp-hdrext/playout-delay');
      if (const int.fromEnvironment('AV_VIDEO_PLAYOUT_MS') > 0) {
        expect(playoutNegotiated, isTrue);
      }
      for (final match in RegExp(
        r'^a=fmtp:(\d+) .*\bapt=(\d+)\b',
        multiLine: true,
      ).allMatches(remoteSdp)) {
        if (payloads.contains(int.parse(match[2]!))) {
          payloads.add(int.parse(match[1]!));
        }
      }
      for (var i = 0; i < (network ? 120 : 20); i++) {
        final phase = {0: 'clean', 20: 'delay', 50: 'offline', 62: 'clean'}[i];
        if (network && phase != null) {
          expect(payloads, isNotEmpty);
          final client = HttpClient();
          try {
            final request = await client.postUrl(
              Uri.parse(
                '${const String.fromEnvironment('AV_MARKER_OUTPUT')}/profile',
              ),
            );
            final bytes = utf8.encode(
              jsonEncode({
                'profile': phase,
                'payload_types': payloads.toList(),
              }),
            );
            request.contentLength = bytes.length;
            request.add(bytes);
            final response = await request.close();
            expect(response.statusCode, 200);
            await response.drain<void>();
          } finally {
            client.close(force: true);
          }
          phases.add([phase, await channel.invokeMethod<double>('clock')]);
        }
        await Future<void>.delayed(const Duration(seconds: 1));
        final stats = await bob.engine.subscriber!.pc.getStats();
        samples.add([
          for (final report in stats)
            if (report.type == 'inbound-rtp')
              {
                for (final field in [
                  'kind',
                  'framesDecoded',
                  'framesDropped',
                  'framesPerSecond',
                  'frameWidth',
                  'frameHeight',
                  'totalDecodeTime',
                  'jitterBufferDelay',
                  'jitterBufferEmittedCount',
                  'jitterBufferTargetDelay',
                  'jitterBufferMinimumDelay',
                  'estimatedPlayoutTimestamp',
                  'totalSamplesReceived',
                  'concealedSamples',
                  'silentConcealedSamples',
                  'concealmentEvents',
                  'insertedSamplesForDeceleration',
                  'removedSamplesForAcceleration',
                  'packetsLost',
                  'packetsReceived',
                  'jitter',
                ])
                  if (report.values[field] != null) field: report.values[field],
              },
        ]);
      }
      final markers = Map<String, dynamic>.from(
        await channel.invokeMapMethod<String, dynamic>('result') ?? {},
      );
      if (network) {
        int packets(int sample, String kind) =>
            ((samples[sample] as List).cast<Map>().firstWhere(
                      (row) => row['kind'] == kind,
                    )['packetsReceived']
                    as num)
                .toInt();
        expect(packets(60, 'video') - packets(52, 'video'), 0);
        expect(packets(60, 'audio') - packets(52, 'audio'), greaterThan(30));
      }
      final chunks = (markers['audio'] as List).cast<Map>();
      markers['audio'] = [
        for (final chunk in chunks)
          {...chunk, 'pcm': base64Encode(chunk['pcm'] as Uint8List)},
      ];
      final result = {
        'markers': markers,
        'stats': samples,
        'missing_key_gate': gate,
        'phases': phases,
        'video_payload_types': payloads.toList(),
        'rtp_playout_delay_negotiated': playoutNegotiated,
        'shared_group': audio.mediaStream.id == video.mediaStream.id,
        'encrypted_publications': true,
        'synthetic_media_only': true,
        'coherent_source': const bool.fromEnvironment('AV_COHERENT_MARKERS'),
        'native_video_playout_ms': nativePlayout,
        'native_video_min_playout_ms': const int.fromEnvironment(
          'AV_NATIVE_VIDEO_MIN_PLAYOUT_MS',
          defaultValue: nativePlayout,
        ),
        'separate_native_sender': role == 'receiver',
      };
      await labPost('', result);
      // ignore: avoid_print
      print(
        'SDK_AV_MARKER_PROOF ${jsonEncode({'shared_group': audio.mediaStream.id == video.mediaStream.id, 'audio_chunks': chunks.length, 'video_markers': (markers['video'] as List).length, 'missing_key_blocked': true})}',
      );
    } finally {
      // Stop the sender before removing the synthetic input replacement.
      if (role != 'receiver') await alice.disconnect();
      for (final track in stream?.getTracks() ?? <rtc.MediaStreamTrack>[]) {
        await track.stop();
      }
      await channel.invokeMethod<void>('stop');
      if (role != 'sender') await bob.disconnect();
      await alice.dispose();
      await bob.dispose();
      await stream?.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
