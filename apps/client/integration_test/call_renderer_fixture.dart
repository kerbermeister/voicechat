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
import 'package:voicechat_probe/media_statistics.dart';
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

  Future<void> waitFor(bool Function() condition) async {
    final watch = Stopwatch()..start();
    while (!condition()) {
      if (watch.elapsed > const Duration(seconds: 15)) {
        throw StateError('Media deadline');
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
        if (response.statusCode != 200) throw StateError('TURN config rejected');
        configuration = jsonDecode(response.body) as Map<String, dynamic>;
        labKey = configuration.remove('lab_key') as String;
        configuration.remove('profile');
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
    final sender = await rtc.createPeerConnection(configuration);
    final receiver = await rtc.createPeerConnection(configuration);
    setState(() => result = 'Peers created; negotiating synthetic A/V');
    final view = createCallRenderer();
    rtc.MediaStream? remote;
    sender.onIceCandidate = (c) {
      if (c.candidate?.isNotEmpty == true) unawaited(receiver.addCandidate(c));
    };
    receiver.onIceCandidate = (c) {
      if (c.candidate?.isNotEmpty == true) unawaited(sender.addCandidate(c));
    };
    receiver.onTrack = (event) {
      remote = event.streams.firstOrNull;
    };
    Future<void> negotiate() async {
      await sender.setLocalDescription(await sender.createOffer());
      await receiver.setRemoteDescription(
        (await sender.getLocalDescription())!,
      );
      await receiver.setLocalDescription(await receiver.createAnswer());
      await sender.setRemoteDescription(
        (await receiver.getLocalDescription())!,
      );
    }

    try {
      await audioReady.timeout(const Duration(seconds: 5));
      await view.initialize();
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
        try {
          for (final phase in [
            ('clean', 6),
            ('delay', 6),
            ('loss', 6),
            ('offline', 3),
            ('clean', 30),
          ]) {
            await profile(phase.$1);
            setState(() => result = 'Network phase: ${phase.$1}');
            for (var i = 0; i < phase.$2; i++) {
              await Future<void>.delayed(const Duration(seconds: 1));
              samples.add({
                'profile': phase.$1,
                'second': samples.length,
                'media': statistics.read(await receiver.getStats()),
              });
            }
          }
          final finalMedia = samples.last['media'] as List<Map<String, Object>>;
          for (final kind in ['audio', 'video']) {
            if (!finalMedia.any(
              (row) =>
                  row['direction'] == 'inbound-rtp' &&
                  row['kind'] == kind &&
                  row['candidateType'] == 'relay' &&
                  row['bitrate_bps'] is num &&
                  (row['bitrate_bps'] as num) > 0,
            )) {
              throw StateError('Relay $kind did not recover');
            }
          }
          final proof = await http.post(
            Uri.base.resolve('/result'),
            headers: {'Content-Type': 'application/json', 'X-Lab-Key': labKey!},
            body: jsonEncode({'rtp_recovered': true, 'samples': samples}),
          );
          if (proof.statusCode != 200) throw StateError('Proof rejected');
        } finally {
          await profile('clean');
        }
      }
      setState(
        () => result =
            'PASS: combined A/V, one audio path, media pause/resume, 320→640 frames, ICE restart, recovered interval counters${networkLab ? ', TURN netem delay/loss/offline recovery' : ''}; physical lip-sync not measured',
      );
    } catch (error) {
      setState(() => result = 'FAIL: $error');
    } finally {
      timer.cancel();
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
        ],
      ),
    ),
  );
}
