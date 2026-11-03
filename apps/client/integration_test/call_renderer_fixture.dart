// Browser-only loopback fixture: synthetic silent audio/video, no account,
// microphone, external signalling, upload or saved media.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamWeb;
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;
import 'package:voicechat_probe/call_renderer.dart';
import 'package:voicechat_probe/call_quality.dart';
import 'package:voicechat_probe/call_audio_platform.dart';

void main() => runApp(const MaterialApp(home: Fixture()));

class Fixture extends StatefulWidget {
  const Fixture({super.key});
  @override
  State<Fixture> createState() => _FixtureState();
}

class _FixtureState extends State<Fixture> {
  String result = 'Ready: local synthetic media only';
  bool running = false;
  rtc.RTCVideoRenderer? renderer;
  rtc.RTCVideoRenderer? reverseRenderer;

  Future<void> waitFor(bool Function() condition) async {
    final watch = Stopwatch()..start();
    while (!condition()) {
      if (watch.elapsed > const Duration(seconds: 15)) {
        throw StateError('Media deadline at $result');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> run() async {
    setState(() {
      running = true;
      result = 'Starting synthetic media';
    });
    // Resume in the click gesture, before fetching the optional lab config.
    final audio = web.AudioContext();
    final audioReady = audio.resume().toDart;
    final networkLab = Uri.base.queryParameters['network_lab'] == '1';
    var configuration = <String, dynamic>{};
    String? labKey;
    var direction = 'both';
    var receiverConfiguration = <String, dynamic>{};
    if (networkLab) {
      if (Uri.base.host != '127.0.0.1') {
        await audio.close().toDart;
        setState(() {
          result = 'FAIL: network fixture requires loopback';
          running = false;
        });
        return;
      }
      try {
        final response = await http
            .get(Uri.base.resolve('/turn.json'))
            .timeout(const Duration(seconds: 5));
        if (response.statusCode != 200) {
          throw StateError('TURN config rejected');
        }
        configuration = jsonDecode(response.body) as Map<String, dynamic>;
        labKey = configuration.remove('lab_key') as String;
        configuration.remove('profile');
        final otherServers = configuration.remove('peer_ice_servers');
        direction = configuration.remove('direction') as String;
        if (!const {'both', 'incoming', 'outgoing'}.contains(direction)) {
          throw StateError('Unknown lab direction');
        }
        receiverConfiguration = {
          ...configuration,
          if (otherServers != null) 'iceServers': otherServers,
        };
      } catch (error) {
        await audio.close().toDart;
        setState(() {
          result = 'FAIL: $error';
          running = false;
        });
        return;
      }
    }
    final oscillator = audio.createOscillator();
    final gain = audio.createGain()..gain.value = 0;
    final destination = audio.createMediaStreamDestination();
    oscillator.connect(gain);
    gain.connect(destination);
    oscillator.start();
    final canvas = web.HTMLCanvasElement()
      ..width = 320
      ..height = 180;
    final drawing = canvas.getContext('2d')! as web.CanvasRenderingContext2D;
    final timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      drawing.fillStyle =
          'hsl(${DateTime.now().millisecondsSinceEpoch % 360} 80% 50%)'.toJS;
      drawing.fillRect(0, 0, canvas.width, canvas.height);
    });
    final source = canvas.callMethod<web.MediaStream>(
      'captureStream'.toJS,
      15.toJS,
    );
    source.addTrack(destination.stream.getAudioTracks().toDart.single);
    final local = MediaStreamWeb(source, 'local');
    final otherLocal = direction == 'both'
        ? null
        : MediaStreamWeb(source.clone(), 'local');
    final sender = await rtc.createPeerConnection(configuration);
    final receiver = await rtc.createPeerConnection(
      networkLab ? receiverConfiguration : configuration,
    );
    setState(() => result = 'Peers created; negotiating synthetic A/V');
    final view = createCallRenderer();
    final otherView = createCallRenderer();
    rtc.MediaStream? otherRemote;
    sender.onTrack = (event) {
      otherRemote = event.streams.firstOrNull;
    };
    rtc.MediaStream? remote;
    final candidatesForSender = <rtc.RTCIceCandidate>[];
    final candidatesForReceiver = <rtc.RTCIceCandidate>[];
    var senderReady = false;
    var receiverReady = false;
    var stopped = false;
    // addIceCandidate requires a remote description, even in local loopback.
    sender.onIceCandidate = (c) {
      if (stopped || c.candidate?.isNotEmpty != true) return;
      if (receiverReady) {
        unawaited(receiver.addCandidate(c));
      } else {
        candidatesForReceiver.add(c);
      }
    };
    receiver.onIceCandidate = (c) {
      if (stopped || c.candidate?.isNotEmpty != true) return;
      if (senderReady) {
        unawaited(sender.addCandidate(c));
      } else {
        candidatesForSender.add(c);
      }
    };
    receiver.onTrack = (event) {
      remote = event.streams.firstOrNull;
    };
    Future<void> negotiate() async {
      await sender.setLocalDescription(await sender.createOffer());
      await receiver.setRemoteDescription(
        (await sender.getLocalDescription())!,
      );
      receiverReady = true;
      for (final candidate in candidatesForReceiver) {
        await receiver.addCandidate(candidate);
      }
      candidatesForReceiver.clear();
      await receiver.setLocalDescription(await receiver.createAnswer());
      await sender.setRemoteDescription(
        (await receiver.getLocalDescription())!,
      );
      senderReady = true;
      for (final candidate in candidatesForSender) {
        await sender.addCandidate(candidate);
      }
      candidatesForSender.clear();
    }

    try {
      await audioReady.timeout(const Duration(seconds: 5));
      await view.initialize();
      if (otherLocal != null) {
        await otherView.initialize();
        for (final track in otherLocal.getTracks()) {
          await receiver.addTrack(track, otherLocal);
        }
      }
      for (final track in local.getTracks()) {
        await sender.addTrack(track, local);
      }
      await negotiate().timeout(const Duration(seconds: 15));
      setState(() => result = 'Negotiated; waiting for frames');
      await waitFor(
        () =>
            remote?.getAudioTracks().length == 1 &&
            remote?.getVideoTracks().length == 1,
      );
      if (otherLocal != null) {
        await waitFor(
          () =>
              otherRemote?.getAudioTracks().length == 1 &&
              otherRemote?.getVideoTracks().length == 1,
        );
        await setCallTrackVolume(otherRemote!.getAudioTracks().single, 0);
        await otherView.setSrcObject(
          stream: otherRemote,
          trackId: otherRemote!.getVideoTracks().single.id,
        );
        setState(() => reverseRenderer = otherView);
      }
      await setCallTrackVolume(remote!.getAudioTracks().single, 0);
      await view.setSrcObject(
        stream: remote,
        trackId: remote!.getVideoTracks().single.id,
      );
      setState(() => renderer = view);
      await waitFor(() => view.videoWidth > 0);
      final video =
          web.document.getElementById(
                'video_RTCVideoRenderer-${view.textureId}',
              )!
              as web.HTMLVideoElement;
      final sound =
          web.document.getElementById(
                'audio_RTCVideoRenderer-${view.textureId}',
              )!
              as web.HTMLAudioElement;
      final combined = video.srcObject! as web.MediaStream;
      if (combined.getAudioTracks().toDart.length != 1 ||
          combined.getVideoTracks().toDart.length != 1 ||
          !sound.muted) {
        throw StateError('Separate or duplicate playout');
      }
      final tracks = await sender.getSenders();
      for (final track in tracks) {
        final parameters = track.parameters;
        for (final encoding in parameters.encodings!) {
          encoding.active = false;
        }
        await track.setParameters(parameters);
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      for (final track in tracks) {
        final parameters = track.parameters;
        for (final encoding in parameters.encodings!) {
          encoding.active = true;
        }
        await track.setParameters(parameters);
      }
      canvas.width = 640;
      canvas.height = 360;
      await waitFor(() => view.videoWidth == 640);
      await sender.restartIce();
      await negotiate().timeout(const Duration(seconds: 15));
      final before = video.currentTime;
      await waitFor(() => video.currentTime > before + .5);
      if (!(video.srcObject! as web.MediaStream).getAudioTracks().toDart.any(
        (t) => t.readyState == 'live',
      )) {
        throw StateError('Audio was lost during recovery');
      }
      final statistics = MediaStatistics();
      statistics.read(await receiver.getStats());
      await Future<void>.delayed(const Duration(seconds: 1));
      final counters = statistics.read(await receiver.getStats());
      if (!counters.any(
        (row) =>
            row['kind'] == 'video' &&
            row['bitrate_bps'] is num &&
            (row['bitrate_bps'] as num) > 0 &&
            row['decoded_fps'] is num &&
            (row['decoded_fps'] as num) > 0,
      )) {
        throw StateError('Recovered video interval counters unavailable');
      }
      final retired = createCallRenderer();
      web.HTMLAudioElement? retiredAudio;
      var retiredDisposed = false;
      try {
        await retired.initialize();
        await retired.setSrcObject(
          stream: remote,
          trackId: remote!.getVideoTracks().single.id,
        );
        retiredAudio =
            web.document.getElementById(
                  'audio_RTCVideoRenderer-${retired.textureId}',
                )
                as web.HTMLAudioElement?;
        if (retiredAudio == null || retiredAudio.srcObject == null) {
          throw StateError('Retired renderer control did not attach audio');
        }
        await retired.dispose();
        retiredDisposed = true;
        if (retiredAudio.srcObject != null) {
          throw StateError(
            'Disposed renderer retained its remote audio source',
          );
        }
        if (combined.getAudioTracks().toDart.single.readyState != 'live') {
          throw StateError('Renderer disposal stopped a shared remote track');
        }
      } finally {
        retiredAudio?.pause();
        retiredAudio?.srcObject = null;
        if (!retiredDisposed) {
          retired.srcObject = null;
          await retired.dispose();
        }
      }
      if (networkLab) {
        Future<void> profile(String name) async {
          final response = await http.post(
            Uri.base.resolve('/profile'),
            headers: {'Content-Type': 'application/json', 'X-Lab-Key': labKey!},
            body: jsonEncode({'profile': name}),
          );
          if (response.statusCode != 200) {
            throw StateError('Network profile rejected');
          }
        }

        final samples = <Map<String, Object>>[];
        final otherStatistics = MediaStatistics();
        final incomingStatistics = CallStatistics();
        final stable = StableCallQuality();
        VideoQuality? appliedVideo;
        var encodingUpdates = 0;
        final autoSender = (await sender.getSenders()).firstWhere(
          (s) => s.track?.kind == 'video',
        );
        try {
          for (final phase
              in (direction == 'both'
                  ? [
                      ('clean', 6),
                      ('delay', 6),
                      ('loss', 6),
                      ('offline', 3),
                      ('clean', 30),
                    ]
                  : [('clean', 9), ('loss', 18), ('clean', 15)])) {
            await profile(phase.$1);
            setState(() => result = 'Network phase: ${phase.$1}');
            for (var i = 0; i < phase.$2; i++) {
              await Future<void>.delayed(const Duration(seconds: 1));
              final otherReports = direction == 'both'
                  ? <rtc.StatsReport>[]
                  : await sender.getStats();
              final incoming = incomingStatistics.read(otherReports);
              final outgoing = outgoingVideoQuality(otherReports);
              if (direction != 'both' && samples.length % 3 == 0) {
                stable.update(outgoing);
                final effective = adaptiveVideoQuality(
                  VideoQuality.auto,
                  stable.value,
                );
                if (effective != appliedVideo) {
                  await applyVideoEncoding(autoSender, effective);
                  appliedVideo = effective;
                  encodingUpdates++;
                }
              }
              samples.add({
                if (direction != 'both') ...{
                  'direction': direction,
                  'encoding_updates': encodingUpdates,
                  'incoming_quality': incoming.name,
                  'outgoing_quality': outgoing.name,
                  'stable_outgoing': stable.value.name,
                  'effective_video': adaptiveVideoQuality(
                    VideoQuality.auto,
                    stable.value,
                  ).name,
                  'reverse_media': otherStatistics.read(otherReports),
                },
                'profile': phase.$1,
                'second': samples.length,
                'media': statistics.read(await receiver.getStats()),
              });
            }
          }
          for (final key in [
            'media',
            if (direction != 'both') 'reverse_media',
          ]) {
            final finalMedia = samples.last[key] as List<Map<String, Object>>;
            for (final kind in ['audio', 'video']) {
              if (!finalMedia.any(
                (row) =>
                    row['direction'] == 'inbound-rtp' &&
                    row['kind'] == kind &&
                    row['candidateType'] == 'relay' &&
                    row['bitrate_bps'] is num &&
                    (row['bitrate_bps'] as num) > 0,
              )) {
                throw StateError('Relay $key $kind did not recover');
              }
            }
          }
          if (direction != 'both') {
            final impaired = samples
                .where((s) => s['profile'] == 'loss')
                .toList();
            bool encodedWidth(Map<String, Object> sample, int width) =>
                (sample['reverse_media'] as List<Map<String, Object>>).any(
                  (r) =>
                      r['direction'] == 'outbound-rtp' &&
                      r['kind'] == 'video' &&
                      r['frameWidth'] == width,
                );
            if (direction == 'incoming') {
              if (impaired
                          .where((s) => s['incoming_quality'] == 'poor')
                          .length <
                      9 ||
                  impaired
                          .where((s) => s['outgoing_quality'] == 'excellent')
                          .length <
                      15 ||
                  !impaired.every(
                    (s) =>
                        s['effective_video'] == 'auto' && encodedWidth(s, 640),
                  )) {
                throw StateError(
                  'Incoming loss incorrectly changed outgoing video',
                );
              }
            } else {
              if (impaired
                          .where((s) => s['outgoing_quality'] == 'poor')
                          .length <
                      9 ||
                  impaired
                          .where((s) => s['incoming_quality'] == 'excellent')
                          .length <
                      15 ||
                  !impaired.any(
                    (s) =>
                        s['effective_video'] == 'low' && encodedWidth(s, 320),
                  )) {
                throw StateError(
                  'Outgoing loss did not adapt video independently',
                );
              }
            }
            if (samples.last['effective_video'] != 'auto' ||
                !encodedWidth(samples.last, 640)) {
              throw StateError(
                'Auto video did not recover after network repair',
              );
            }
          }
          final proof = await http.post(
            Uri.base.resolve('/result'),
            headers: {'Content-Type': 'application/json', 'X-Lab-Key': labKey!},
            body: jsonEncode({'rtp_recovered': true, 'samples': samples}),
          );
          if (proof.statusCode != 200) {
            throw StateError(
              'Proof rejected ${proof.statusCode}: ${proof.body} (${proof.request?.contentLength} bytes)',
            );
          }
        } finally {
          await profile('clean');
        }
      }
      setState(
        () => result =
            'PASS: combined A/V, one audio path, disposed source released/shared track live, media pause/resume, 320→640 frames, ICE restart, recovered interval counters${networkLab ? ', TURN network recovery ($direction)' : ''}; physical lip-sync not measured',
      );
    } catch (error) {
      setState(
        () => result =
            'FAIL: $error; ICE ${sender.iceConnectionState?.name}/${receiver.iceConnectionState?.name}',
      );
    } finally {
      stopped = true;
      timer.cancel();
      if (otherLocal != null) otherView.srcObject = null;
      for (final t
          in otherRemote?.getAudioTracks() ?? <rtc.MediaStreamTrack>[]) {
        forgetCallTrackVolume(t.id!);
      }
      for (final t in otherLocal?.getTracks() ?? <rtc.MediaStreamTrack>[]) {
        await t.stop();
      }
      if (otherLocal != null) await otherView.dispose();
      oscillator.stop();
      for (final track in local.getTracks()) {
        await track.stop();
      }
      for (final track
          in remote?.getAudioTracks() ?? <rtc.MediaStreamTrack>[]) {
        forgetCallTrackVolume(track.id!);
      }
      view.srcObject = null;
      await sender.close();
      await receiver.close();
      await view.dispose();
      await audio.close().toDart;
      setState(() {
        renderer = null;
        reverseRenderer = null;
        running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          FilledButton(
            onPressed: running ? null : run,
            child: const Text('Run renderer checks'),
          ),
          SelectableText(result),
          if (renderer != null) Expanded(child: rtc.RTCVideoView(renderer!)),
          if (reverseRenderer != null)
            Expanded(child: rtc.RTCVideoView(reverseRenderer!)),
        ],
      ),
    ),
  );
}
