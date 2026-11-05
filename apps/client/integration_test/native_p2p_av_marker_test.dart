// Account-free native PeerConnections. Media and captured PCM are synthetic.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
// Pinned native SDK log stream; diagnostic runs only.
// ignore: implementation_imports
import 'package:flutter_webrtc/src/native/event_channel.dart';
import 'package:integration_test/integration_test.dart';

import 'native_av_marker_test.dart' show labPost, captureNativeMarkers;

const _channel = MethodChannel('voicechat/native-av-lab');

Future<StreamSubscription<Map<String, dynamic>>?> collectNativeSyncLogs(
  List<Map<String, dynamic>> logs,
) async {
  if (!const bool.fromEnvironment('P2P_NATIVE_SYNC_LOGS')) return null;
  final subscription = FlutterWebRTCEventChannel.instance.handleEvents.stream
      .listen((event) async {
        final value = event['onLogData'];
        final message = value is Map ? value['data'] : null;
        if (message is String &&
            logs.length < 100 &&
            (message.contains('Sync info stats:') ||
                message.contains('Sync delay stats:') ||
                message.contains('Resetting jitter estimator') ||
                message.contains('Frame has bad render timing') ||
                message.contains('Target video delay is too large') ||
                message.contains('Resetting filter.'))) {
          logs.add({
            'time': await _channel.invokeMethod<double>('clock'),
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

Future<void> gatherRelay(rtc.RTCPeerConnection pc) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 15)) {
    final sdp = (await pc.getLocalDescription())?.sdp ?? '';
    // One usable relay is enough; other interfaces can keep gathering. The
    // fixture verifies the selected pair after the authenticated handshake.
    if (RegExp(r'a=candidate:[^\r\n]+ typ relay').hasMatch(sdp)) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  final sdp = (await pc.getLocalDescription())?.sdp ?? '';
  final types = RegExp(
    r'\btyp (\w+)',
  ).allMatches(sdp).map((m) => m[1]).toList();
  fail(
    'No native relay candidate: state=${pc.iceGatheringState}, types=$types',
  );
}

Future<void> negotiateP2P(
  rtc.RTCPeerConnection sender,
  rtc.RTCPeerConnection receiver, {
  bool wrongFingerprint = false,
  bool audioOnly = false,
}) async {
  if (const bool.fromEnvironment('P2P_PREFER_VP8')) {
    if (Platform.isMacOS) {
      await _channel.invokeMethod<void>('preferVP8');
    } else {
      final caps = await rtc.getRtpReceiverCapabilities('video');
      final codecs = caps.codecs!;
      final ordered = [
        ...codecs.where((c) => c.mimeType.toLowerCase() == 'video/vp8'),
        ...codecs.where((c) => c.mimeType.toLowerCase() != 'video/vp8'),
      ];
      for (final transceiver in await sender.getTransceivers()) {
        if (transceiver.sender.track?.kind == 'video') {
          await transceiver.setCodecPreferences(ordered);
        }
      }
    }
  }
  final offer = audioOnly
      ? await sender.createOffer({
          'mandatory': {
            'OfferToReceiveAudio': true,
            'OfferToReceiveVideo': false,
          },
          'optional': <dynamic>[],
        })
      : await sender.createOffer();
  await sender.setLocalDescription(offer);
  await gatherRelay(sender);
  await receiver.setRemoteDescription((await sender.getLocalDescription())!);
  await receiver.setLocalDescription(await receiver.createAnswer());
  await gatherRelay(receiver);
  final answer = (await receiver.getLocalDescription())!;
  var sdp = answer.sdp!;
  if (wrongFingerprint) {
    final expression = RegExp(r'(a=fingerprint:sha-256 )([0-9A-Fa-f]{2})');
    expect(expression.hasMatch(sdp), isTrue);
    sdp = sdp.replaceAllMapped(
      expression,
      (match) => '${match[1]}${match[2] == '00' ? '01' : '00'}',
    );
  }
  await sender.setRemoteDescription(
    rtc.RTCSessionDescription(sdp, answer.type),
  );
}

Future<void> closePeer(rtc.RTCPeerConnection pc) async {
  await pc.close();
  await pc.dispose();
}

Future<Map<String, dynamic>> measureP2PReceiver(
  rtc.RTCPeerConnection receiver,
  rtc.RTCRtpReceiver audio,
  rtc.RTCRtpReceiver? video, {
  required bool split,
  required int playout,
  required Map<String, Object?> cryptoControl,
  rtc.RTCPeerConnection? audioControl,
}) async {
  Future<void> profile(String name, Set<int> payloads) => labPost('/profile', {
    'profile': name,
    'payload_types': payloads.toList(),
  });
  final audioOnly = video == null;
  const impairAudio = bool.fromEnvironment('P2P_IMPAIR_AUDIO');
  const delayOnly = bool.fromEnvironment('P2P_DELAY_ONLY');
  expect(impairAudio && delayOnly, isFalse);
  expect(
    impairAudio && (audioOnly || audioControl != null),
    isFalse,
    reason:
        'Audio-stall recovery uses one video call; the paired voice reference must remain intact',
  );
  await _channel.invokeMethod<void>('observe', {
    'audio': audio.track!.id,
    if (video != null) 'video': video.track!.id,
  });
  var initial = await receiver.getStats();
  for (var attempt = 0; attempt < 150; attempt++) {
    if (initial.any(
      (s) =>
          s.type == 'inbound-rtp' &&
          s.values['kind'] == (audioOnly ? 'audio' : 'video') &&
          (audioOnly
              ? (s.values['packetsReceived'] as num? ?? 0) > 0
              : (s.values['framesDecoded'] as num? ?? 0) > 0),
    )) {
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    initial = await receiver.getStats();
  }
  // ignore: avoid_print
  print(
    'P2P_NATIVE_READINESS ${jsonEncode([
      for (final s in initial)
        if (s.type == 'inbound-rtp') {
            for (final key in ['kind', 'packetsReceived', 'framesDecoded']) key: s.values[key],
          },
    ])}',
  );
  expect(
    initial.any(
      (s) =>
          s.type == 'inbound-rtp' &&
          s.values['kind'] == (audioOnly ? 'audio' : 'video') &&
          (audioOnly
              ? (s.values['packetsReceived'] as num? ?? 0) > 0
              : (s.values['framesDecoded'] as num? ?? 0) > 0),
    ),
    isTrue,
    reason:
        'Require a decoded video frame before measuring or choosing RTP filters',
  );
  final transport = initial.firstWhere(
    (s) => s.type == 'transport' && s.values['dtlsState'] == 'connected',
  );
  final cipher = transport.values['srtpCipher'];
  expect(cipher, isA<String>());
  expect((cipher as String).isNotEmpty, isTrue);
  final byId = {for (final s in initial) s.id: s};
  final selected = byId[transport.values['selectedCandidatePairId']]!;
  expect(
    byId[selected.values['localCandidateId']]!.values['candidateType'],
    'relay',
  );
  expect(
    byId[selected.values['remoteCandidateId']]!.values['candidateType'],
    'relay',
  );
  final sourceSdp = (await receiver.getRemoteDescription())!.sdp!;
  Set<int> mediaPayloads(String kind) {
    final match = RegExp(
      '^m=$kind [^\\r\\n]+',
      multiLine: true,
    ).firstMatch(sourceSdp);
    if (match == null) {
      return {};
    }
    return match[0]!
        .trim()
        .split(RegExp(r'\s+'))
        .skip(3)
        .map(int.parse)
        .toSet();
  }

  // Classify every negotiated video PT, including RED/ULPFEC and their RTX.
  // Codec stats can expose the inner VP8 PT while the wire carries RED.
  final payloads = mediaPayloads('video');
  expect(payloads.intersection(mediaPayloads('audio')), isEmpty);
  expect(payloads.isEmpty, audioOnly);
  final profilePayloads = audioOnly
      ? {
          List.generate(
            32,
            (i) => i + 96,
          ).firstWhere((pt) => !mediaPayloads('audio').contains(pt)),
        }
      : impairAudio
      ? mediaPayloads('audio')
      : payloads;
  // ignore: avoid_print
  print(
    'P2P_NATIVE_CODECS ${jsonEncode([
      for (final row in initial)
        if (row.type == 'codec') {'mime': row.values['mimeType'], 'payload': row.values['payloadType']},
    ])}',
  );
  final samples = <List<Map<String, dynamic>>>[], phases = <List<Object?>>[];
  final sampleTimes = <double>[];
  final controlSamples = <List<Map<String, dynamic>>>[];
  for (var i = 0; i < 120; i++) {
    final next = {
      0: 'clean',
      20: 'delay',
      50: delayOnly ? 'clean' : 'offline',
      62: 'clean',
    }[i];
    if (next != null) {
      await profile(next, profilePayloads);
      phases.add([next, await _channel.invokeMethod<double>('clock')]);
    }
    await Future<void>.delayed(const Duration(seconds: 1));
    final stats = await receiver.getStats();
    sampleTimes.add((await _channel.invokeMethod<double>('clock'))!);
    samples.add([
      for (final s in stats)
        if (s.type == 'inbound-rtp')
          {
            for (final field in [
              'kind',
              'ssrc',
              'framesDecoded',
              'framesDropped',
              'framesPerSecond',
              'frameWidth',
              'frameHeight',
              'jitterBufferDelay',
              'jitterBufferEmittedCount',
              'jitterBufferTargetDelay',
              'jitterBufferMinimumDelay',
              'estimatedPlayoutTimestamp',
              'insertedSamplesForDeceleration',
              'removedSamplesForAcceleration',
              'totalSamplesReceived',
              'concealedSamples',
              'packetsReceived',
              'packetsLost',
              'jitter',
            ])
              if (s.values[field] != null) field: s.values[field],
          },
    ]);
    if (audioControl != null) {
      controlSamples.add([
        for (final row in await audioControl.getStats())
          if (row.type == 'inbound-rtp') Map<String, dynamic>.from(row.values),
      ]);
    }
  }
  num packets(int sample, String kind) =>
      samples[sample].firstWhere((s) => s['kind'] == kind)['packetsReceived']
          as num;
  if (delayOnly && !audioOnly) {
    for (final kind in ['audio', 'video']) {
      expect(packets(60, kind) - packets(52, kind), greaterThan(30));
    }
  } else if (!audioOnly) {
    final blocked = impairAudio ? 'audio' : 'video';
    final continuing = impairAudio ? 'video' : 'audio';
    expect(packets(60, blocked) - packets(52, blocked), 0);
    expect(packets(60, continuing) - packets(52, continuing), greaterThan(30));
  } else {
    expect(packets(60, 'audio') - packets(52, 'audio'), greaterThan(30));
  }
  if (audioControl != null) {
    num controlPackets(int sample) =>
        controlSamples[sample].singleWhere(
              (row) => row['kind'] == 'audio',
            )['packetsReceived']
            as num;
    expect(controlPackets(60) - controlPackets(52), greaterThan(30));
    expect(
      controlSamples
          .expand((rows) => rows)
          .any((row) => row['kind'] == 'video'),
      isFalse,
    );
  }

  final markers = await captureNativeMarkers(_channel);
  return {
    'synthetic_media_only': true,
    'audio_only': audioOnly,
    'delay_only': delayOnly,
    'markers': markers,
    'stats': samples,
    'stats_times': sampleTimes,
    if (audioControl != null) 'control_stats': controlSamples,
    'phases': phases,
    'shared_group': !split,
    'video_payload_types': payloads.toList(),
    'impaired_media_kind': impairAudio ? 'audio' : 'video',
    'p2p': true,
    'video_playout_ms': playout,
    'separate_streams': split,
    'crypto_control': {
      ...cryptoControl,
      'positive_dtls_connected': true,
      'srtp_cipher': cipher,
    },
  };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native P2P A/V after video-only TURN impairment', (
    tester,
  ) async {
    const origin = String.fromEnvironment('P2P_LAB_URL');
    final http = HttpClient();
    final configReply = await (await http.getUrl(
      Uri.parse('$origin/turn.json'),
    )).close();
    expect(configReply.statusCode, 200);
    final config =
        jsonDecode(await utf8.decoder.bind(configReply).join())
            as Map<String, dynamic>;
    http.close(force: true);
    expect(config['iceTransportPolicy'], 'relay');
    const split = bool.fromEnvironment('P2P_SEPARATE_STREAMS');
    const productSync = bool.fromEnvironment('P2P_PRODUCT_SYNC');
    const audioOnly = bool.fromEnvironment('P2P_AUDIO_ONLY');
    const keepOriginal = bool.fromEnvironment('P2P_KEEP_ORIGINAL_STREAM');
    const playout = int.fromEnvironment('P2P_VIDEO_PLAYOUT_MS');
    if (playout != 0) {
      await _channel.invokeMethod<void>('playout', {
        'milliseconds': playout,
        'minimum': const int.fromEnvironment(
          'P2P_VIDEO_MIN_PLAYOUT_MS',
          defaultValue: playout,
        ),
      });
    }
    final stream = await rtc.navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    final peers = <rtc.RTCPeerConnection>[];
    final videoStream = split && !productSync
        ? await rtc.createLocalMediaStream('synthetic-video')
        : stream;
    try {
      await _channel.invokeMethod<void>('create', {
        'stream': stream.id,
        'coherent': const bool.fromEnvironment('AV_COHERENT_MARKERS'),
        'speech': base64Decode(
          const String.fromEnvironment('AV_SPEECH_BASE64'),
        ),
      });
      // ignore: deprecated_member_use
      await stream.getMediaTracks();
      Future<(rtc.RTCPeerConnection, rtc.RTCPeerConnection)> pair() async {
        // The receiver uses the listener selected by the video-only egress filter.
        final receiver = await rtc.createPeerConnection({
          'iceServers': config['peer_ice_servers'],
          'iceTransportPolicy': 'relay',
          'bundlePolicy': 'max-bundle',
          'sdpSemantics': 'unified-plan',
        });
        peers.add(receiver);
        final sender = await rtc.createPeerConnection({
          'iceServers': config['iceServers'],
          'separateVideoSync': split && productSync,
          'iceTransportPolicy': 'relay',
          'bundlePolicy': 'max-bundle',
          'sdpSemantics': 'unified-plan',
        });
        peers.add(sender);
        for (final track in stream.getTracks()) {
          if (audioOnly && track.kind == 'video') {
            continue;
          }
          final added = await sender.addTrack(
            track,
            track.kind == 'video' && !productSync ? videoStream : stream,
          );
          if (split && keepOriginal && !productSync && track.kind == 'video') {
            await added.setStreams([videoStream, stream]);
          }
        }
        return (sender, receiver);
      }

      Future<(bool, num)> negativePair() async {
        final (badSender, badReceiver) = await pair();
        await negotiateP2P(
          badSender,
          badReceiver,
          wrongFingerprint: true,
          audioOnly: audioOnly,
        );
        var dtlsFailed = false;
        for (var i = 0; i < 60; i++) {
          dtlsFailed = (await badSender.getStats()).any(
            (s) => s.type == 'transport' && s.values['dtlsState'] == 'failed',
          );
          if (dtlsFailed) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          dtlsFailed,
          isTrue,
          reason: 'A wrong remote certificate must fail authentication',
        );
        final negativePackets = (await badReceiver.getStats())
            .where((s) => s.type == 'inbound-rtp')
            .fold<num>(
              0,
              (sum, row) => sum + (row.values['packetsReceived'] as num? ?? 0),
            );
        expect(negativePackets, 0);
        await closePeer(badSender);
        peers.remove(badSender);
        await closePeer(badReceiver);
        peers.remove(badReceiver);
        return (dtlsFailed, negativePackets);
      }

      const cryptoAfter = bool.fromEnvironment('P2P_CRYPTO_AFTER');
      var negativeControl = (false, 0 as num);
      if (!cryptoAfter) negativeControl = await negativePair();
      final (sender, receiver) = await pair();
      final remoteStreamIds = <String, String>{};
      final remoteAudio = Completer<rtc.RTCRtpReceiver>(),
          remoteVideo = Completer<rtc.RTCRtpReceiver>();
      receiver.onTrack = (event) {
        expect(
          event.streams,
          hasLength(
            split && keepOriginal && event.track.kind == 'video' ? 2 : 1,
          ),
        );
        remoteStreamIds[event.track.kind!] = event.streams.first.id;
        if (keepOriginal && event.track.kind == 'video') {
          expect(event.streams.last.id, stream.id);
          if (productSync) {
            expect(
              event.streams.first.id,
              'video-${stream.getVideoTracks().single.id}',
            );
          }
          expect(event.streams.last.getTracks().map((t) => t.kind).toSet(), {
            'audio',
            'video',
          });
        }
        if (event.track.kind == 'audio' && !remoteAudio.isCompleted) {
          remoteAudio.complete(event.receiver!);
        }
        if (event.track.kind == 'video' && !remoteVideo.isCompleted) {
          remoteVideo.complete(event.receiver!);
        }
      };
      await negotiateP2P(sender, receiver, audioOnly: audioOnly);
      final audio = await remoteAudio.future.timeout(
        const Duration(seconds: 15),
      );
      final video = audioOnly
          ? null
          : await remoteVideo.future.timeout(const Duration(seconds: 15));
      if (!audioOnly) {
        expect(remoteStreamIds['audio'] == remoteStreamIds['video'], !split);
      }
      final measured = await measureP2PReceiver(
        receiver,
        audio,
        video,
        split: split,
        playout: playout,
        cryptoControl: {
          'protocol': 'DTLS-SRTP',
          'negative_dtls_failed': negativeControl.$1,
          'negative_received_media_packets': negativeControl.$2,
        },
      );
      if (cryptoAfter) {
        await closePeer(sender);
        peers.remove(sender);
        await closePeer(receiver);
        peers.remove(receiver);
        negativeControl = await negativePair();
        (measured['crypto_control'] as Map)['negative_dtls_failed'] =
            negativeControl.$1;
        (measured['crypto_control'] as Map)['negative_received_media_packets'] =
            negativeControl.$2;
      }
      measured['crypto_control_after_timing'] = cryptoAfter;
      measured['coherent_source'] = const bool.fromEnvironment(
        'AV_COHERENT_MARKERS',
      );
      measured['original_stream_preserved'] = keepOriginal;
      measured['product_sync'] = productSync;
      measured['video_min_playout_ms'] = const int.fromEnvironment(
        'P2P_VIDEO_MIN_PLAYOUT_MS',
        defaultValue: playout,
      );
      await labPost('', measured);
      // ignore: avoid_print
      print(
        'NATIVE_P2P_AV_PROOF ${jsonEncode({'dtls_negative_blocked': negativeControl.$1, 'crypto_control': measured['crypto_control'], 'relay_only': true})}',
      );
    } finally {
      for (final pc in peers.reversed) {
        await closePeer(pc);
      }
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await _channel.invokeMethod<void>('stop');
      if (split && !identical(videoStream, stream)) await videoStream.dispose();
      await stream.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
