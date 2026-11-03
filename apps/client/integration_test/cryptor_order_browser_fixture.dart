// Real worker/GCM with a test-only delayed WebCrypto result; no accounts/capture.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamWeb;
// ignore: implementation_imports
import 'package:dart_webrtc/src/frame_cryptor_impl.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:web/web.dart' as web;

import 'key_epoch_probe.dart';

void main() {
  if (!{'localhost', '127.0.0.1', '::1'}.contains(Uri.base.host)) {
    throw StateError('Loopback frame-order fixture required');
  }
  if (!{
    'none',
    'encrypt',
    'decrypt',
  }.contains(Uri.base.queryParameters['operation'] ?? 'none')) {
    throw StateError('Unknown frame-order operation');
  }
  if (Uri.base.queryParameters['transform'] == 'encoded_streams') {
    if (!web.window.delete('RTCRtpScriptTransform'.toJS).toDart) {
      throw StateError('Cannot select encoded-streams fixture control');
    }
  }
  runApp(const MaterialApp(home: CryptorOrderFixture()));
}

Future<Map> control(Map<String, Object> command) async {
  final worker = FrameCryptorFactoryImpl.instance.worker;
  final msgId = 'fixture-${DateTime.now().microsecondsSinceEpoch}';
  final reply = Completer<Map>();
  final listener = ((web.MessageEvent event) {
    final value = event.data.dartify();
    if (value is Map &&
        value['msgType'] == 'fixture-order-result' &&
        value['msgId'] == msgId &&
        !reply.isCompleted) {
      reply.complete(value['data'] as Map);
    }
  }).toJS;
  worker.addEventListener('message', listener);
  try {
    worker.postMessage(
      {'msgType': 'fixture-order-control', 'msgId': msgId, ...command}.jsify(),
    );
    final data = await reply.future.timeout(const Duration(seconds: 5));
    if (data.containsKey('error')) throw StateError('Fixture command rejected');
    return data;
  } finally {
    worker.removeEventListener('message', listener);
  }
}

class CryptorOrderFixture extends StatefulWidget {
  const CryptorOrderFixture({super.key});
  @override
  State<CryptorOrderFixture> createState() => _CryptorOrderFixtureState();
}

class _CryptorOrderFixtureState extends State<CryptorOrderFixture> {
  var result = 'Ready: real GCM; ordered WebCrypto completion control';
  var running = false;
  var finished = false;
  rtc.RTCVideoRenderer? renderer;

  Future<void> run() async {
    setState(() => running = true);
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
      var invalidDelayRejected = false;
      try {
        await control({
          'command': 'configure',
          'operation': 'encrypt',
          'delayMs': 501,
        });
      } on StateError {
        invalidDelayRejected = true;
      }
      if (!invalidDelayRejected) {
        throw StateError('Unbounded fixture delay accepted');
      }
      // One operation per fresh page/worker: late frames of an older probe
      // must never consume the first-operation fault or affect its counters.
      final operation = Uri.base.queryParameters['operation'] ?? 'none';
      setState(() => result = 'Running $operation order control');
      final configured = await control({
        'command': 'configure',
        'operation': operation,
        'delayMs': operation == 'none' ? 0 : 500,
      });
      if (configured['configured'] != true) {
        throw StateError('Fixture was not configured');
      }
      Map<String, Object>? media;
      String? mediaError;
      try {
        media = await runKeyEpochProbe(
          capture: () async => MediaStreamWeb(
            canvas.callMethod<web.MediaStream>('captureStream'.toJS, 15.toJS),
            'local',
          ),
          configuration: {'iceServers': [], 'encodedInsertableStreams': true},
          onRenderer: (value) {
            if (mounted) setState(() => renderer = value);
          },
        );
      } catch (error) {
        mediaError = '${error.runtimeType}';
      }
      final counts = await control({'command': 'summary'});
      final controllers = (counts['controllers'] as List).cast<Map>();
      final valid =
          counts['operation'] == operation &&
          counts['delayMs'] == (operation == 'none' ? 0 : 500) &&
          controllers.length == 2 &&
          controllers.every((row) => (row['writes'] as num) >= 6) &&
          (operation == 'none' || counts['delayed'] == true);
      final ordered = controllers.every((value) => value['backwardSteps'] == 0);
      final passed = valid && media != null && ordered;
      final proof = {
        'fresh_worker_per_page': true,
        'invalid_delay_rejected': invalidDelayRejected,
        'transform_api':
            web.window.hasProperty('RTCRtpScriptTransform'.toJS).toDart
            ? 'script_transform'
            : 'encoded_streams',
        'cases': [
          {
            'operation': operation,
            'instrumentation_valid': valid,
            'media_probe_completed': media != null,
            if (mediaError != null) 'media_error_type': mediaError,
            'worker': counts,
            if (media != null) 'media': media,
          },
        ],
      };
      result =
          '${passed ? 'PASS' : 'FAIL'} FRAME_ORDER_PROOF ${jsonEncode(proof)}';
    } catch (error) {
      result = 'INCOMPLETE: ${error.runtimeType}';
    } finally {
      timer.cancel();
      if (mounted) {
        setState(() {
          running = false;
          finished = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Encrypted frame ordering fixture')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        FilledButton(
          onPressed: running || finished ? null : run,
          child: Text(
            finished ? 'Reload to repeat' : 'Run frame order control',
          ),
        ),
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
