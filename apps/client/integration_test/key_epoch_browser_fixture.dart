// Browser-only SDK probe: synthetic video, no microphone/account/upload.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamWeb;
// ignore: implementation_imports
import 'package:dart_webrtc/src/frame_cryptor_impl.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:web/web.dart' as web;

import 'key_epoch_probe.dart';

void main() {
  if (!{'localhost', '127.0.0.1', '::1'}.contains(Uri.base.host)) {
    throw StateError('Loopback key-epoch fixture required');
  }
  if (Uri.base.queryParameters['transform'] == 'encoded_streams') {
    // Exercise the supported legacy branch in a disposable fixture tab only.
    if (!web.window.delete('RTCRtpScriptTransform'.toJS).toDart) {
      throw StateError('Cannot select encoded-streams fixture control');
    }
  }
  runApp(const MaterialApp(home: KeyEpochFixture()));
}

Future<Map<String, bool>> checkWorkerRejections(
  web.HTMLCanvasElement canvas,
) async {
  final provider = await lk.BaseKeyProvider.create(sharedKey: false);
  var providerDisposed = false;
  final factory = FrameCryptorFactoryImpl.instance;
  final missing = FrameCryptorImpl(
    factory,
    factory.worker,
    'fixture-sender',
    'fixture-missing-track',
    keyProvider: provider.keyProvider as KeyProviderImpl,
  );
  Future<bool> rejects(Future<Object?> Function() command) async {
    try {
      await command();
      return false;
    } catch (_) {
      return true;
    }
  }

  final peer = await rtc.createPeerConnection({
    'iceServers': [],
    'encodedInsertableStreams': true,
  });
  final source = MediaStreamWeb(
    canvas.callMethod<web.MediaStream>('captureStream'.toJS, 15.toJS),
    'local',
  );
  try {
    final proof = {
      'missing_index_rejected': await rejects(() => missing.setKeyIndex(1)),
      'missing_index_cache_preserved': await missing.keyIndex == 0,
      'missing_enable_rejected': await rejects(() => missing.setEnabled(true)),
      'missing_enable_cache_preserved': !(await missing.enabled),
      'missing_codec_rejected': await rejects(() => missing.updateCodec('vp8')),
      'missing_dispose_rejected': await rejects(missing.dispose),
    };
    final sender = await peer.addTrack(source.getVideoTracks().single, source);
    await provider.keyProvider.dispose();
    providerDisposed = true;
    proof['missing_provider_setup_rejected'] = await rejects(
      () => factory.createFrameCryptorForRtpSender(
        participantId: 'fixture-sender',
        sender: sender,
        algorithm: rtc.Algorithm.kAesGcm,
        keyProvider: provider.keyProvider,
      ),
    );
    final receiving = await peer.addTransceiver(
      kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo,
    );
    proof['missing_provider_receiver_setup_rejected'] = await rejects(
      () => factory.createFrameCryptorForRtpReceiver(
        participantId: 'fixture-sender',
        receiver: receiving.receiver,
        algorithm: rtc.Algorithm.kAesGcm,
        keyProvider: provider.keyProvider,
      ),
    );
    if (proof.values.any((value) => !value)) {
      throw StateError('Worker rejection was not preserved: $proof');
    }
    return proof;
  } finally {
    for (final track in source.getTracks()) {
      await track.stop();
    }
    await peer.close();
    await source.dispose();
    if (!providerDisposed) await provider.keyProvider.dispose();
  }
}

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
      proof['worker_rejections'] = await checkWorkerRejections(canvas);
      proof['transform_api'] =
          web.window.hasProperty('RTCRtpScriptTransform'.toJS).toDart
          ? 'script_transform'
          : 'encoded_streams';
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
