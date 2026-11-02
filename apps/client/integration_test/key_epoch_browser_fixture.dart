// Browser-only SDK probe: synthetic video, no microphone/account/upload.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamWeb;
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:web/web.dart' as web;

import 'key_epoch_probe.dart';

void main() => runApp(const MaterialApp(home: KeyEpochFixture()));

class KeyEpochFixture extends StatefulWidget {
  const KeyEpochFixture({super.key});
  @override
  State<KeyEpochFixture> createState() => _KeyEpochFixtureState();
}

class _KeyEpochFixtureState extends State<KeyEpochFixture> {
  String result = 'Ready: synthetic video; real GCM frame encryption';
  bool running = false;
  rtc.RTCVideoRenderer? renderer;

  Future<void> run() async {
    setState(() {
      running = true;
      result = 'Running encrypted loopback';
    });
    final canvas = web.HTMLCanvasElement()
      ..width = 320
      ..height = 180;
    final drawing = canvas.getContext('2d')! as web.CanvasRenderingContext2D;
    final timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      drawing.fillStyle =
          'hsl(${DateTime.now().millisecondsSinceEpoch % 360} 80% 50%)'.toJS;
      drawing.fillRect(0, 0, canvas.width, canvas.height);
    });
    try {
      final proof = await runKeyEpochProbe(
        capture: () async => MediaStreamWeb(
          canvas.callMethod<web.MediaStream>('captureStream'.toJS, 15.toJS),
          'local',
        ),
        configuration: {'iceServers': [], 'encodedInsertableStreams': true},
        initialSlot: int.parse(Uri.base.queryParameters['initial_slot'] ?? '0'),
        onRenderer: (value) {
          if (mounted) setState(() => renderer = value);
        },
      );
      if (mounted) {
        setState(() => result = 'PASS KEY_EPOCH_PROOF ${jsonEncode(proof)}');
      }
    } catch (error) {
      if (mounted) setState(() => result = 'FAIL: $error');
    } finally {
      timer.cancel();
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Encrypted key epoch fixture')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        FilledButton(
          onPressed: running ? null : run,
          child: const Text('Run encrypted probe'),
        ),
        const SizedBox(height: 16),
        Semantics(
          label: result,
          liveRegion: true,
          child: ExcludeSemantics(child: SelectableText(result)),
        ),
        if (renderer != null)
          SizedBox(height: 180, child: rtc.RTCVideoView(renderer!)),
      ],
    ),
  );
}
