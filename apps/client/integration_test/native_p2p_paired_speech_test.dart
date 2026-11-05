// Simultaneous ordinary voice reference: same native source clock and host load.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:integration_test/integration_test.dart';

import 'native_av_marker_test.dart' show labPost;
import 'native_p2p_av_marker_test.dart'
    show negotiateP2P, closePeer, measureP2PReceiver, collectNativeSyncLogs;

const channel = MethodChannel('voicechat/native-av-lab');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('video and simultaneous ordinary voice use the same source', (
    tester,
  ) async {
    final http = HttpClient();
    final config =
        jsonDecode(
              await utf8.decoder
                  .bind(
                    await (await http.getUrl(
                      Uri.parse(
                        '${const String.fromEnvironment('P2P_LAB_URL')}/turn.json',
                      ),
                    )).close(),
                  )
                  .join(),
            )
            as Map<String, dynamic>;
    http.close(force: true);
    final streams = <rtc.MediaStream>[];
    final peers = <rtc.RTCPeerConnection>[];
    final syncLogs = <Map<String, dynamic>>[];
    StreamSubscription<Map<String, dynamic>>? nativeLogs;
    try {
      const playout = int.fromEnvironment('P2P_VIDEO_PLAYOUT_MS');
      const minPlayout = int.fromEnvironment(
        'P2P_VIDEO_MIN_PLAYOUT_MS',
        defaultValue: playout,
      );
      const audioOnly = bool.fromEnvironment('P2P_AUDIO_ONLY');
      const timestampReset = int.fromEnvironment('P2P_TIMESTAMP_RESET_MS');
      const fullReset = bool.fromEnvironment('P2P_TIMESTAMP_FULL_RESET');
      const adaptivePlayout = bool.fromEnvironment(
        'P2P_ADAPTIVE_VIDEO_PLAYOUT',
      );
      if (adaptivePlayout) expect(fullReset, isTrue);
      if (timestampReset != 0 || fullReset) {
        expect(playout, 0);
        await channel.invokeMethod<void>('timestampReset', {
          'milliseconds': timestampReset,
          'fullReset': fullReset,
          'adaptiveVideo': adaptivePlayout,
        });
      }
      if (playout != 0) {
        await channel.invokeMethod<void>('playout', {
          'milliseconds': playout,
          'minimum': minPlayout,
        });
      }
      nativeLogs = await collectNativeSyncLogs(syncLogs);
      for (var i = 0; i < 2; i++) {
        streams.add(
          await rtc.navigator.mediaDevices.getUserMedia({
            'audio': true,
            'video': false,
          }),
        );
      }
      expect(
        streams[0].getAudioTracks().single.id,
        isNot(streams[1].getAudioTracks().single.id),
      );
      await channel.invokeMethod<void>('create', {
        'stream': streams.first.id,
        'coherent': true,
        'speech': base64Decode(
          const String.fromEnvironment('AV_SPEECH_BASE64'),
        ),
      });
      // ignore: deprecated_member_use
      await streams.first.getMediaTracks();
      Future<(rtc.RTCPeerConnection, rtc.RTCPeerConnection)> pair(
        int index,
      ) async {
        final receiver = await rtc.createPeerConnection({
          'iceServers': config['peer_ice_servers'],
          'iceTransportPolicy': 'relay',
          'bundlePolicy': 'max-bundle',
          'sdpSemantics': 'unified-plan',
        });
        peers.add(receiver);
        final sender = await rtc.createPeerConnection({
          'iceServers': config['iceServers'],
          'iceTransportPolicy': 'relay',
          'bundlePolicy': 'max-bundle',
          'sdpSemantics': 'unified-plan',
        });
        peers.add(sender);
        for (final track in streams[index].getTracks()) {
          if (audioOnly && track.kind == 'video') continue;
          await sender.addTrack(track, streams[index]);
        }
        return (sender, receiver);
      }

      Future<Map<String, Object?>> proof(rtc.RTCPeerConnection receiver) async {
        for (var i = 0; i < 150; i++) {
          final rows = await receiver.getStats();
          if (!rows.any(
            (r) =>
                r.type == 'inbound-rtp' &&
                r.values['kind'] == 'audio' &&
                (r.values['packetsReceived'] as num? ?? 0) > 0,
          )) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            continue;
          }
          final transport = rows.singleWhere(
            (r) =>
                r.type == 'transport' && r.values['dtlsState'] == 'connected',
          );
          final byId = {for (final r in rows) r.id: r};
          final selected = byId[transport.values['selectedCandidatePairId']]!;
          for (final key in ['localCandidateId', 'remoteCandidateId']) {
            expect(
              byId[selected.values[key]]!.values['candidateType'],
              'relay',
            );
          }
          expect(transport.values['srtpCipher'], isA<String>());
          return {
            'protocol': 'DTLS-SRTP',
            'positive_dtls_connected': true,
            'srtp_cipher': transport.values['srtpCipher'],
          };
        }
        fail('Ordinary voice reference did not receive audio');
      }

      Future<Map<String, Object?>> negative(int index) async {
        final (sender, receiver) = await pair(index);
        await negotiateP2P(
          sender,
          receiver,
          wrongFingerprint: true,
          audioOnly: audioOnly || index == 1,
        );
        var failed = false;
        for (var i = 0; i < 60; i++) {
          failed = (await sender.getStats()).any(
            (r) => r.type == 'transport' && r.values['dtlsState'] == 'failed',
          );
          if (failed) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(failed, isTrue);
        final packets = (await receiver.getStats())
            .where((r) => r.type == 'inbound-rtp')
            .fold<num>(
              0,
              (sum, r) => sum + (r.values['packetsReceived'] as num? ?? 0),
            );
        expect(packets, 0);
        await closePeer(sender);
        peers.remove(sender);
        await closePeer(receiver);
        peers.remove(receiver);
        return {
          'negative_dtls_failed': failed,
          'negative_received_media_packets': packets,
        };
      }

      const referenceFirst = bool.fromEnvironment('P2P_REFERENCE_FIRST');
      final first = await pair(referenceFirst ? 1 : 0);
      final second = await pair(referenceFirst ? 0 : 1);
      final (sender, receiver) = referenceFirst ? second : first;
      final (controlSender, controlReceiver) = referenceFirst ? first : second;
      final audio = Completer<rtc.RTCRtpReceiver>(),
          video = Completer<rtc.RTCRtpReceiver>(),
          controlAudio = Completer<rtc.RTCRtpReceiver>();
      final ids = <String, String>{};
      receiver.onTrack = (e) {
        expect(e.streams, hasLength(1));
        ids[e.track.kind!] = e.streams.single.id;
        expect(e.streams.single.id, streams.first.id);
        if (e.track.kind == 'video') {
          expect(e.streams.single.getTracks().map((t) => t.kind).toSet(), {
            'audio',
            'video',
          });
          if (!video.isCompleted) video.complete(e.receiver!);
        } else {
          if (!audio.isCompleted) audio.complete(e.receiver!);
        }
      };
      controlReceiver.onTrack = (e) {
        expect(e.track.kind, 'audio');
        expect(e.streams, hasLength(1));
        expect(e.streams.single.id, streams[1].id);
        if (!controlAudio.isCompleted) controlAudio.complete(e.receiver!);
      };
      await Future.wait([
        if (referenceFirst)
          negotiateP2P(controlSender, controlReceiver, audioOnly: true),
        negotiateP2P(sender, receiver, audioOnly: audioOnly),
        if (!referenceFirst)
          negotiateP2P(controlSender, controlReceiver, audioOnly: true),
      ]);
      Future<List<String>> audioCodec(rtc.RTCPeerConnection pc) async {
        final sdp = (await pc.getLocalDescription())!.sdp!;
        final opus = RegExp(
          r'^a=rtpmap:(\d+) opus/[^\r\n]+',
          multiLine: true,
        ).firstMatch(sdp)!;
        return [
          opus[0]!,
          ...RegExp(
            '^a=fmtp:${opus[1]} [^\\r\\n]+',
            multiLine: true,
          ).allMatches(sdp).map((m) => m[0]!),
        ];
      }

      final codec = await audioCodec(sender),
          controlCodec = await audioCodec(controlSender);
      expect(
        codec,
        controlCodec,
        reason:
            'Ordinary voice and video must negotiate identical Opus parameters',
      );
      final remoteAudio = await audio.future.timeout(
        const Duration(seconds: 15),
      );
      final remoteVideo = audioOnly
          ? null
          : await video.future.timeout(const Duration(seconds: 15));
      final referenceAudio = await controlAudio.future.timeout(
        const Duration(seconds: 15),
      );
      expect(remoteAudio.track!.id, isNot(referenceAudio.track!.id));
      if (audioOnly) {
        expect(video.isCompleted, isFalse);
      } else {
        expect(ids['audio'], ids['video']);
      }
      final controlProof = await proof(controlReceiver);
      await channel.invokeMethod<void>('observeControl', {
        'audio': referenceAudio.track!.id,
      });
      final result = await measureP2PReceiver(
        receiver,
        remoteAudio,
        remoteVideo,
        split: false,
        playout: playout,
        audioControl: controlReceiver,
        cryptoControl: {'protocol': 'DTLS-SRTP'},
      );
      result['audio_codec_parameters'] = {
        'video_call': codec,
        'ordinary_voice': controlCodec,
      };
      for (final entry in {
        'video_call': sender,
        'ordinary_voice': controlSender,
      }.entries) {
        result['${entry.key}_audio_sender'] = [
          for (final row in await entry.value.getStats())
            if (row.type == 'outbound-rtp' && row.values['kind'] == 'audio')
              {
                for (final name in [
                  'bytesSent',
                  'packetsSent',
                  'targetBitrate',
                  'codecId',
                ])
                  if (row.values[name] != null) name: row.values[name],
              },
        ];
      }
      for (final peer in [sender, receiver, controlSender, controlReceiver]) {
        await closePeer(peer);
        peers.remove(peer);
      }
      (result['crypto_control'] as Map).addAll(await negative(0));
      result['audio_control_crypto'] = {...controlProof, ...await negative(1)};
      result['simultaneous_ordinary_voice_reference'] = true;
      result['speech_reference_calibration'] = audioOnly;
      result['reference_started_first'] = referenceFirst;
      result['coherent_source'] = true;
      result['product_sync'] = true;
      result['original_stream_preserved'] = true;
      result['timestamp_reset_ms'] = timestampReset;
      result['timestamp_full_covariance_reset'] = fullReset;
      result['adaptive_video_playout'] = adaptivePlayout;
      result['video_min_playout_ms'] = minPlayout;
      if (syncLogs.isNotEmpty) result['native_sync_logs'] = syncLogs;
      // Retain the source pulse trace before rejecting an invalid source.
      await labPost('', result);
      final source = (result['markers'] as Map)['source_audio'] as List;
      expect(source.length, greaterThan(50));
      for (var i = 1; i < source.length; i++) {
        final seconds = (source[i][1] as num) - (source[i - 1][1] as num);
        final ids = (source[i][0] as num) - (source[i - 1][0] as num);
        expect(
          seconds / ids,
          inInclusiveRange(1.8, 2.2),
          reason: 'Two audio tracks must share one physical capture clock',
        );
      }
    } finally {
      await nativeLogs?.cancel();
      for (final pc in peers.reversed) {
        await closePeer(pc);
      }
      await channel.invokeMethod<void>('stop');
      for (final stream in streams) {
        for (final track in stream.getTracks()) {
          await track.stop();
        }
        await stream.dispose();
      }
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
