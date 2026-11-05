// Real native SDK/SFU media; synthetic tones and bitmaps, no account or camera.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:flutter_webrtc/src/native/event_channel.dart';
import 'package:integration_test/integration_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:livekit_client/src/core/engine.dart';
import 'package:voicechat_probe/call_stream_sync.dart';

Future<StreamSubscription<Map<String, dynamic>>> collectNativeSifLogs(
  List<Map<String, dynamic>> logs,
) async {
  final watch = Stopwatch()..start();
  final subscription = FlutterWebRTCEventChannel.instance.handleEvents.stream
      .listen((event) {
        final value = event['onLogData'];
        final message = value is Map ? value['data'] : null;
        if (message is String &&
            logs.length < 300 &&
            (message.contains('server injected frame') ||
                message.contains('SIF trailer'))) {
          logs.add({
            'elapsed_us': watch.elapsedMicroseconds,
            'message': message,
          });
        }
      });
  try {
    await rtc.WebRTC.initialize(options: {'logSeverity': 'info'});
  } catch (_) {
    await subscription.cancel();
    rethrow;
  }
  return subscription;
}

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

/// Read bounded PCM pages; a full paired recording can exceed Android's heap
/// while StandardMessageCodec builds its single contiguous reply buffer.
Future<Map<String, dynamic>> captureNativeMarkers(MethodChannel channel) async {
  final markers = Map<String, dynamic>.from(
    await channel.invokeMapMethod<String, dynamic>('result', {
          'includeAudio': false,
        }) ??
        {},
  );
  if (markers['audio'] is! List) {
    throw StateError('Missing native PCM stream');
  }
  for (final name in ['audio', 'control_audio']) {
    if (markers[name] == null && !markers.containsKey('${name}_count')) {
      continue;
    }
    if (markers[name] is! List) {
      throw StateError('Missing native PCM stream');
    }
    final chunks = <Map<String, dynamic>>[];
    void append(List rows) {
      for (final row in rows.cast<Map>()) {
        chunks.add({
          ...Map<String, dynamic>.from(row),
          'pcm': base64Encode(row['pcm'] as Uint8List),
        });
      }
    }

    if (markers.containsKey('${name}_count')) {
      final count = markers.remove('${name}_count');
      if (count is! int || count < 0 || count > 14000) {
        throw StateError('Invalid PCM snapshot count');
      }
      for (var offset = 0; offset < count; offset += 128) {
        final size = min(128, count - offset);
        final page = await channel.invokeListMethod<dynamic>('audioChunks', {
          'control': name == 'control_audio',
          'offset': offset,
          'limit': size,
        });
        if (page == null || page.length != size) {
          throw StateError('Incomplete PCM page');
        }
        append(page);
      }
    } else {
      append(markers[name] as List);
    }
    markers[name] = chunks;
  }
  return markers;
}

void expectSourceCadence(List source) {
  expect(source.length, greaterThan(50));
  for (var i = 1; i < source.length; i++) {
    final seconds = (source[i][1] as num) - (source[i - 1][1] as num);
    final ids = (source[i][0] as num) - (source[i - 1][0] as num);
    expect(seconds / ids, inInclusiveRange(1.8, 2.2));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native encrypted audio/video marker playout', (tester) async {
    const channel = MethodChannel('voicechat/native-av-lab');
    const nativePlayout = int.fromEnvironment('AV_NATIVE_VIDEO_PLAYOUT_MS');
    const fullReset = bool.fromEnvironment('AV_TIMESTAMP_FULL_RESET');
    const adaptivePlayout = bool.fromEnvironment('AV_ADAPTIVE_VIDEO_PLAYOUT');
    final fixtureOverrides = {
      'timestamp_full_reset': fullReset,
      'adaptive_video': adaptivePlayout,
      'video_playout_ms': nativePlayout,
    };
    if (adaptivePlayout) expect(fullReset, isTrue);
    if (fullReset) {
      expect(nativePlayout, 0);
      await channel.invokeMethod<void>('timestampReset', {
        'milliseconds': 0,
        'fullReset': true,
        'adaptiveVideo': adaptivePlayout,
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
    const ordinaryVoice = bool.fromEnvironment('AV_ORDINARY_VOICE_REFERENCE');
    const keylessMuteCycle = bool.fromEnvironment('AV_KEYLESS_MUTE_CYCLE');
    const nativeCallSync = bool.fromEnvironment('AV_NATIVE_CALL_SYNC');
    const dropKeylessSif = bool.fromEnvironment('AV_DROP_KEYLESS_SIF');
    if (dropKeylessSif) expect(keylessMuteCycle, isTrue);
    if (keylessMuteCycle) {
      expect(ordinaryVoice, isTrue);
    }
    final sifLogs = <Map<String, dynamic>>[];
    final nativeSifLogs = keylessMuteCycle
        ? await collectNativeSifLogs(sifLogs)
        : null;

    const encodedKey = String.fromEnvironment('AV_MARKER_KEY');
    final key = encodedKey.isNotEmpty
        ? base64Decode(encodedKey)
        : Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
    expect(key.length, 32);
    expect({'both', 'sender', 'receiver'}, contains(role));
    // Match the product controllers; the upstream default permits empty frames.
    final sendKeys = await lk.BaseKeyProvider.create(
      sharedKey: false,
      discardFrameWhenCryptorNotReady: true,
    );
    final receiveKeys = await lk.BaseKeyProvider.create(
      sharedKey: false,
      discardFrameWhenCryptorNotReady: true,
    );
    expect(sendKeys.options.discardFrameWhenCryptorNotReady, isTrue);
    expect(receiveKeys.options.discardFrameWhenCryptorNotReady, isTrue);
    if (Platform.isAndroid &&
        const bool.fromEnvironment('AV_NATIVE_OUTPUT_CLOCK')) {
      await channel.invokeMethod<void>('observeOutputClock');
    }
    await sendKeys.setRawKey(key, participantId: 'alice');
    final alice = lk.Room(
      roomOptions: lk.RoomOptions(
        encryption: lk.E2EEOptions(keyProvider: sendKeys),
      ),
    );
    final options = lk.RoomOptions(
      encryption: lk.E2EEOptions(keyProvider: receiveKeys),
    );
    final bob = lk.Room(
      roomOptions: options,
      engine: Engine(
        connectOptions: const lk.ConnectOptions(),
        roomOptions: options,
        subscriberDescriptionTransform: nativeCallSync
            ? synchronizeCallStreams
            : null,
      ),
    );
    rtc.MediaStream? stream;
    rtc.MediaStream? voiceStream;
    lk.Room? voiceAlice;
    lk.Room? voiceBob;
    lk.BaseKeyProvider? voiceReceiveKeys;
    lk.RemoteAudioTrack? voiceAudio;
    try {
      const url = String.fromEnvironment('GROUP_TEST_URL');
      if (ordinaryVoice) {
        final voiceSendKeys = await lk.BaseKeyProvider.create(
          sharedKey: false,
          discardFrameWhenCryptorNotReady: true,
        );
        voiceReceiveKeys = await lk.BaseKeyProvider.create(
          sharedKey: false,
          discardFrameWhenCryptorNotReady: true,
        );
        expect(voiceSendKeys.options.discardFrameWhenCryptorNotReady, isTrue);
        expect(
          voiceReceiveKeys.options.discardFrameWhenCryptorNotReady,
          isTrue,
        );
        await voiceSendKeys.setRawKey(key, participantId: 'voice-alice');
        voiceAlice = lk.Room(
          roomOptions: lk.RoomOptions(
            encryption: lk.E2EEOptions(keyProvider: voiceSendKeys),
          ),
        );
        voiceBob = lk.Room(
          roomOptions: lk.RoomOptions(
            encryption: lk.E2EEOptions(keyProvider: voiceReceiveKeys),
          ),
        );
        if (role != 'sender') {
          await voiceBob.connect(
            url,
            const String.fromEnvironment('AV_VOICE_BOB'),
          );
          expect(voiceBob.name, 'route-probe-voice');
        }
        if (role != 'receiver') {
          await voiceAlice.connect(
            url,
            const String.fromEnvironment('AV_VOICE_ALICE'),
          );
        }
      }
      if (role != 'sender') {
        await bob.connect(url, const String.fromEnvironment('GROUP_TEST_BOB'));
        if (dropKeylessSif) {
          // Diagnostic only: distinguish SFU blank-frame/PLC output from media.
          // Never used as a positive crypto or production-parity qualification.
          await receiveKeys.setSifTrailer(Uint8List(0));
          await voiceReceiveKeys!.setSifTrailer(Uint8List(0));
        }
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
        if (ordinaryVoice) {
          voiceStream = await rtc.navigator.mediaDevices.getUserMedia({
            'audio': true,
            'video': false,
          });
        }
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
        if (ordinaryVoice) {
          final voiceTrack = lk.LocalAudioTrack(
            lk.TrackSource.microphone,
            voiceStream!,
            voiceStream.getAudioTracks().single,
            const lk.AudioCaptureOptions(),
          );
          final publication = await voiceAlice!.localParticipant!
              .publishAudioTrack(
                voiceTrack,
                publishOptions: const lk.AudioPublishOptions(
                  stream: 'ordinary-voice',
                ),
              );
          expect(publication.encryptionType, lk.EncryptionType.kGcm);
          expect(voiceAlice.localParticipant!.videoTrackPublications, isEmpty);
        }
        if (role == 'sender') {
          if (keylessMuteCycle) {
            await labWait('keyless_mute_requested');
            await alice.localParticipant!.setMicrophoneEnabled(false);
            await Future<void>.delayed(const Duration(milliseconds: 250));
            await alice.localParticipant!.setMicrophoneEnabled(true);
            await labPost('/mute', {'sender_muted_unmuted': true});
          }
          await labWait('receiver_done');
          final markers = await channel.invokeMapMethod<String, dynamic>(
            'result',
          );
          if (ordinaryVoice && !keylessMuteCycle) {
            expectSourceCadence(markers!['source_audio'] as List);
          }
          await labPost('/source', {
            'source_audio': markers!['source_audio'],
            'source_video': markers['source_video'],
            'source_video_frames': markers['source_video_frames'],
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
        if (ordinaryVoice) {
          voiceAudio = voiceBob!
              .remoteParticipants['voice-alice']
              ?.audioTrackPublications
              .firstOrNull
              ?.track;
        }
        if (audio != null &&
            video != null &&
            (!ordinaryVoice || voiceAudio != null)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(audio, isNotNull);
      expect(video, isNotNull);
      if (nativeCallSync) {
        expect(audio!.mediaStream.id, video!.mediaStream.id);
        expect(audio.mediaStream.id, endsWith('|voicechat-call'));
        expect(audio.mediaStreamTrack.id, startsWith('TR_'));
        expect(video.mediaStreamTrack.id, startsWith('TR_'));
      }
      await channel.invokeMethod<void>('observe', {
        'audio': audio!.mediaStreamTrack.id,
        'video': video!.mediaStreamTrack.id,
      });
      final streamGroups = {
        'audio': audio.mediaStream.id,
        'video': video.mediaStream.id,
        'audio_track': audio.mediaStreamTrack.id,
        'video_track': video.mediaStreamTrack.id,
      };
      if (ordinaryVoice) {
        expect(bob.name, 'route-probe');
        expect(
          voiceBob!.engine.subscriber!.pc,
          isNot(same(bob.engine.subscriber!.pc)),
        );
        await channel.invokeMethod<void>('observeControl', {
          'audio': voiceAudio!.mediaStreamTrack.id,
        });
      }
      if (keylessMuteCycle) {
        if (role == 'receiver') {
          await labPost('/mute', {'keyless_mute_requested': true});
          await labWait('sender_muted_unmuted');
        } else {
          await alice.localParticipant!.setMicrophoneEnabled(false);
          await Future<void>.delayed(const Duration(milliseconds: 250));
          await alice.localParticipant!.setMicrophoneEnabled(true);
        }
      }
      await Future<void>.delayed(const Duration(seconds: 3));
      final gate = <String, Object>{};
      final contentGate = await channel.invokeMapMethod<String, dynamic>(
        'gate',
      );
      if ((contentGate!['video_markers'] as num) != 0 ||
          (contentGate['audio_peak'] as num) >= .001 ||
          (ordinaryVoice &&
              (contentGate['control_audio_peak'] as num) >= .001)) {
        // Preserve synthetic PCM and decoder counters before rejecting the
        // negative control; no keys are installed and no assertion is relaxed.
        final reports = await bob.engine.subscriber!.pc.getStats();
        final voiceReports = ordinaryVoice
            ? await voiceBob!.engine.subscriber!.pc.getStats()
            : <rtc.StatsReport>[];
        List<Object> counters(List<rtc.StatsReport> rows) => [
          for (final row in rows)
            if (row.type == 'inbound-rtp')
              {
                for (final key in [
                  'kind',
                  'packetsReceived',
                  'packetsLost',
                  'totalSamplesReceived',
                  'concealedSamples',
                  'silentConcealedSamples',
                  'concealmentEvents',
                  'framesDecoded',
                ])
                  if (row.values[key] != null) key: row.values[key],
              },
        ];
        await labPost('', {
          'synthetic_media_only': true,
          'key_gate_failed': true,
          'separate_native_sender': role == 'receiver',
          'discard_frame_when_cryptor_not_ready': true,
          'native_call_sync': nativeCallSync,
          'shared_group': audio.mediaStream.id == video.mediaStream.id,
          'stream_groups': streamGroups,
          'keys_installed': false,
          'markers': await captureNativeMarkers(channel),
          'stats': counters(reports),
          'control_stats': counters(voiceReports),
          'missing_key_gate': {'content': contentGate},
          'simultaneous_ordinary_voice_reference': ordinaryVoice,
          'native_sif_logs': sifLogs,
          'keyless_mute_cycle': keylessMuteCycle,
        });
      }
      expect(contentGate['video_markers'], 0);
      expect(contentGate['audio_peak'], lessThan(.001));
      gate['content'] = contentGate;
      if (ordinaryVoice) {
        expect(contentGate['control_audio_peak'], lessThan(.001));
        final rows = await voiceAudio!.receiver!.getStats();
        final inbound = rows.singleWhere(
          (r) => r.type == 'inbound-rtp' && r.values['kind'] == 'audio',
        );
        expect(inbound.values['packetsReceived'], greaterThan(0));
        gate['ordinary_voice'] = {
          'packets': inbound.values['packetsReceived'],
          'plaintext_audio_peak': contentGate['control_audio_peak'],
          'decoded':
              (inbound.values['totalSamplesReceived'] as num? ?? 0) -
              (inbound.values['concealedSamples'] as num? ?? 0),
        };
      }
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
      if (keylessMuteCycle) {
        await labPost('', {
          'synthetic_media_only': true,
          'key_gate_only': true,
          'separate_native_sender': role == 'receiver',
          'fixture_field_trial_overrides': fixtureOverrides,
          'drop_keyless_sif_diagnostic': dropKeylessSif,
          'keys_installed': false,
          'native_call_sync': nativeCallSync,
          'shared_group': audio.mediaStream.id == video.mediaStream.id,
          'stream_groups': streamGroups,
          'markers': await captureNativeMarkers(channel),
          'missing_key_gate': gate,
          'native_sif_logs': sifLogs,
          'discard_frame_when_cryptor_not_ready': true,
        });
        // This is solely a negative crypto control, not a media qualification.
        // ignore: avoid_print
        print(
          'SDK_AV_KEY_GATE_PROOF ${jsonEncode({'missing_key_blocked': true, 'ordinary_missing_key_blocked': true, 'keys_installed': false, 'positive_media_qualified': false})}',
        );
        return;
      }
      await Future.wait([
        receiveKeys.setRawKey(key, participantId: 'alice'),
        if (ordinaryVoice)
          voiceReceiveKeys!.setRawKey(key, participantId: 'voice-alice'),
      ]);
      final samples = <Object>[];
      final voiceSamples = <Object>[];
      final sampleTimes = <double>[];
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
      List<Object> inboundStats(List<rtc.StatsReport> stats) => [
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
      ];
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
        samples.add(inboundStats(stats));
        if (ordinaryVoice) {
          final voiceStats = await voiceBob!.engine.subscriber!.pc.getStats();
          voiceSamples.add(inboundStats(voiceStats));
          expect(
            voiceStats.where(
              (r) => r.type == 'inbound-rtp' && r.values['kind'] == 'video',
            ),
            isEmpty,
          );
          if (i == 0) {
            Map<String, dynamic> audioCodec(List<rtc.StatsReport> rows) {
              final audio = rows.singleWhere(
                (r) => r.type == 'inbound-rtp' && r.values['kind'] == 'audio',
              );
              final codec = rows
                  .singleWhere((r) => r.id == audio.values['codecId'])
                  .values;
              return {
                for (final key in [
                  'mimeType',
                  'clockRate',
                  'channels',
                  'sdpFmtpLine',
                ])
                  key: codec[key],
              };
            }

            expect(audioCodec(voiceStats), audioCodec(stats));
          }
        }
        sampleTimes.add((await channel.invokeMethod<double>('clock'))!);
      }
      final markers = await captureNativeMarkers(channel);
      if (ordinaryVoice && role != 'receiver') {
        expectSourceCadence(markers['source_audio'] as List);
      }
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
      final result = {
        'markers': markers,
        'fixture_field_trial_overrides': fixtureOverrides,
        'stats': samples,
        'stats_times': sampleTimes,
        'simultaneous_ordinary_voice_reference': ordinaryVoice,
        'native_sif_logs': sifLogs,
        'keyless_mute_cycle': keylessMuteCycle,
        if (ordinaryVoice) 'control_stats': voiceSamples,
        if (ordinaryVoice) 'ordinary_voice_room': voiceBob!.name,
        if (ordinaryVoice)
          'ordinary_voice_stream': {
            'audio': voiceAudio!.mediaStream.id,
            'audio_track': voiceAudio.mediaStreamTrack.id,
          },
        'missing_key_gate': gate,
        'phases': phases,
        'video_payload_types': payloads.toList(),
        'rtp_playout_delay_negotiated': playoutNegotiated,
        'shared_group': audio.mediaStream.id == video.mediaStream.id,
        'native_call_sync': nativeCallSync,
        'stream_groups': streamGroups,
        'encrypted_publications': true,
        'synthetic_media_only': true,
        'coherent_source': const bool.fromEnvironment('AV_COHERENT_MARKERS'),
        'native_video_playout_ms': nativePlayout,
        'timestamp_full_covariance_reset': fullReset,
        'adaptive_video_playout': adaptivePlayout,
        'discard_frame_when_cryptor_not_ready': true,
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
      if (role != 'receiver') await voiceAlice?.disconnect();
      if (role != 'receiver') await alice.disconnect();
      for (final track in stream?.getTracks() ?? <rtc.MediaStreamTrack>[]) {
        await track.stop();
      }
      await channel.invokeMethod<void>('stop');
      if (role != 'sender') await bob.disconnect();
      await alice.dispose();
      await bob.dispose();
      for (final track
          in voiceStream?.getTracks() ?? <rtc.MediaStreamTrack>[]) {
        await track.stop();
      }
      if (role != 'sender') await voiceBob?.disconnect();
      await voiceAlice?.dispose();
      await voiceBob?.dispose();
      await voiceStream?.dispose();
      await stream?.dispose();
      await nativeSifLogs?.cancel();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
