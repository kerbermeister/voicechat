// Separate native sender: the Android emulator's ADC is not a timing source.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:integration_test/integration_test.dart';

import 'native_av_marker_test.dart' show labPost, labWait;
import 'native_p2p_av_marker_test.dart'
    show gatherRelay, closePeer, measureP2PReceiver;

const channel = MethodChannel('voicechat/native-av-lab');

Future<dynamic> signal(String key) async {
  await labWait(key);
  final http = HttpClient();
  try {
    final response = await (await http.getUrl(
      Uri.parse(
        '${const String.fromEnvironment('AV_MARKER_OUTPUT')}/signal/$key',
      ),
    )).close();
    expect(response.statusCode, 200);
    return jsonDecode(await utf8.decoder.bind(response).join());
  } finally {
    http.close(force: true);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('separate native P2P sender and receiver', (tester) async {
    const sender = bool.fromEnvironment('P2P_SENDER');
    const audioOnly = bool.fromEnvironment('P2P_AUDIO_ONLY');
    const split = bool.fromEnvironment('P2P_SEPARATE_STREAMS');
    const productSync = bool.fromEnvironment('P2P_PRODUCT_SYNC');
    const playout = int.fromEnvironment('P2P_VIDEO_PLAYOUT_MS');
    final peers = <rtc.RTCPeerConnection>[];
    rtc.MediaStream? stream, videoStream;
    try {
      if (playout != 0) {
        await channel.invokeMethod<void>('playout', {'milliseconds': playout});
      }
      if (sender) {
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
        videoStream = split && !productSync
            ? await rtc.createLocalMediaStream('synthetic-video')
            : stream;
      } else {
        await channel.invokeMethod<void>('receive');
      }
      final config = await signal('config');
      if (!sender) {
        await labPost('/signal', {'key': 'receiver_ready', 'value': true});
      }
      Future<rtc.RTCPeerConnection> pair() async {
        final pc = await rtc.createPeerConnection({
          'iceServers': config[sender ? 'iceServers' : 'peer_ice_servers'],
          'separateVideoSync': sender && split && productSync,
          'iceTransportPolicy': 'relay',
          'bundlePolicy': 'max-bundle',
          'sdpSemantics': 'unified-plan',
        });
        peers.add(pc);
        if (sender) {
          for (final track in stream!.getTracks()) {
            if (audioOnly && track.kind == 'video') continue;
            await pc.addTrack(
              track,
              track.kind == 'video' && !productSync ? videoStream! : stream,
            );
          }
        }
        return pc;
      }

      Future<void> negotiate(rtc.RTCPeerConnection pc, String round) async {
        if (sender) {
          await pc.setLocalDescription(await pc.createOffer());
          await gatherRelay(pc);
          final offer = (await pc.getLocalDescription())!;
          await labPost('/signal', {
            'key': '${round}_offer',
            'value': offer.toMap(),
          });
          final answer = await signal('${round}_answer');
          var sdp = answer['sdp'] as String;
          if (round == 'negative') {
            final pattern = RegExp(r'(a=fingerprint:sha-256 )([0-9A-Fa-f]{2})');
            expect(pattern.hasMatch(sdp), isTrue);
            sdp = sdp.replaceAllMapped(
              pattern,
              (m) => '${m[1]}${m[2] == '00' ? '01' : '00'}',
            );
          }
          await pc.setRemoteDescription(
            rtc.RTCSessionDescription(sdp, answer['type'] as String),
          );
        } else {
          final offer = await signal('${round}_offer');
          await pc.setRemoteDescription(
            rtc.RTCSessionDescription(
              offer['sdp'] as String,
              offer['type'] as String,
            ),
          );
          await pc.setLocalDescription(await pc.createAnswer());
          await gatherRelay(pc);
          await labPost('/signal', {
            'key': '${round}_answer',
            'value': (await pc.getLocalDescription())!.toMap(),
          });
        }
      }

      final negative = await pair();
      await negotiate(negative, 'negative');
      if (sender) {
        var failed = false;
        for (var i = 0; i < 60; i++) {
          failed = (await negative.getStats()).any(
            (s) => s.type == 'transport' && s.values['dtlsState'] == 'failed',
          );
          if (failed) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(failed, isTrue);
        await labPost('/signal', {'key': 'negative_failed', 'value': failed});
        await signal('negative_packets');
      } else {
        expect(await signal('negative_failed'), true);
        final packets = (await negative.getStats())
            .where((s) => s.type == 'inbound-rtp')
            .fold<num>(
              0,
              (sum, s) => sum + (s.values['packetsReceived'] as num? ?? 0),
            );
        expect(packets, 0);
        await labPost('/signal', {'key': 'negative_packets', 'value': packets});
      }
      await closePeer(negative);
      peers.remove(negative);
      final positive = await pair();
      final audio = Completer<rtc.RTCRtpReceiver>(),
          video = Completer<rtc.RTCRtpReceiver>();
      final ids = <String, String>{};
      rtc.MediaStream? originalVideoStream;
      positive.onTrack = (event) {
        expect(
          event.streams,
          hasLength(
            split && productSync && event.track.kind == 'video' ? 2 : 1,
          ),
        );
        ids[event.track.kind!] = event.streams.first.id;
        if (productSync && event.track.kind == 'video') {
          expect(event.streams.first.id, startsWith('video-'));
          originalVideoStream = event.streams.last;
        }
        if (event.track.kind == 'audio' && !audio.isCompleted) {
          audio.complete(event.receiver!);
        }
        if (event.track.kind == 'video' && !video.isCompleted) {
          video.complete(event.receiver!);
        }
      };
      await negotiate(positive, 'positive');
      if (sender) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final diagnostics = await positive.getStats();
        // ignore: avoid_print
        print(
          'P2P_SENDER_COUNTERS ${jsonEncode([
            for (final row in diagnostics)
              if (row.type == 'outbound-rtp' || row.type == 'codec') {
                  for (final key in ['kind', 'packetsSent', 'framesEncoded', 'mimeType'])
                    if (row.values[key] != null) key: row.values[key],
                },
          ])}',
        );
        await labWait('receiver_done');
        final markers = (await channel.invokeMapMethod<String, dynamic>(
          'result',
        ))!;
        await labPost('/source', {
          for (final name in ['source_audio', 'source_video'])
            name: markers[name],
        });
      } else {
        final remoteAudio = await audio.future.timeout(
          const Duration(seconds: 20),
        );
        final remoteVideo = audioOnly
            ? null
            : await video.future.timeout(const Duration(seconds: 20));
        if (audioOnly) {
          expect(ids['video'], isNull);
        } else {
          expect(ids['audio'] == ids['video'], !split);
        }
        if (!audioOnly && productSync) {
          expect(originalVideoStream!.id, ids['audio']);
          // ignore: deprecated_member_use
          await originalVideoStream!.getMediaTracks();
          expect(originalVideoStream!.getTracks().map((t) => t.kind).toSet(), {
            'audio',
            'video',
          });
        }
        final result = await measureP2PReceiver(
          positive,
          remoteAudio,
          remoteVideo,
          split: split,
          playout: playout,
          cryptoControl: {
            'protocol': 'DTLS-SRTP',
            'negative_dtls_failed': await signal('negative_failed'),
            'negative_received_media_packets': await signal('negative_packets'),
          },
        );
        result['separate_native_sender'] = true;
        result['product_sync'] = productSync;
        result['original_stream_preserved'] = productSync;
        result['coherent_source'] = const bool.fromEnvironment(
          'AV_COHERENT_MARKERS',
        );
        await labPost('', result);
      }
    } finally {
      for (final pc in peers.reversed) {
        await closePeer(pc);
      }
      for (final track in stream?.getTracks() ?? <rtc.MediaStreamTrack>[]) {
        await track.stop();
      }
      await channel.invokeMethod<void>('stop');
      if (videoStream != null && !identical(stream, videoStream)) {
        await videoStream.dispose();
      }
      await stream?.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
