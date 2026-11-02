// Real SDK/SFU/worker, synthetic canvas only. No account, camera or microphone.
// ignore_for_file: invalid_use_of_internal_member
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamWeb;
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:web/web.dart' as web;

void main() => runApp(const MaterialApp(home: SdkPublicationFixture()));

Future<Map<String, Object>> probeBrowserPublication() async {
  void require(bool value, String message) {
    if (!value) throw StateError(message);
  }

  final response = await web.window.fetch('/probe.json'.toJS).toDart;
  require(response.ok, 'Local probe configuration unavailable');
  final config = jsonDecode((await response.text().toDart).toDart) as Map;
  final keys = await lk.BaseKeyProvider.create(sharedKey: false);
  final recipientKeys = await lk.BaseKeyProvider.create(sharedKey: false);
  final random = Random.secure();
  Uint8List key() =>
      Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
  final initial = key(), prepared = key();
  await keys.setRawKey(initial, participantId: 'alice');
  final alice = lk.Room(
    roomOptions: lk.RoomOptions(encryption: lk.E2EEOptions(keyProvider: keys)),
  );
  final bob = lk.Room(
    roomOptions: lk.RoomOptions(
      encryption: lk.E2EEOptions(keyProvider: recipientKeys),
    ),
  );
  final observer = lk.Room();
  final canvas = web.HTMLCanvasElement()
    ..width = 320
    ..height = 180;
  final drawing = canvas.getContext('2d')! as web.CanvasRenderingContext2D;
  final timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
    drawing.fillStyle =
        'hsl(${DateTime.now().millisecondsSinceEpoch % 360} 80% 50%)'.toJS;
    drawing.fillRect(0, 0, canvas.width, canvas.height);
  });
  final views = <rtc.RTCVideoRenderer>[];
  Future<lk.RemoteVideoTrack> remote(lk.Room room, String sid) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(seconds: 15)) {
      final track = room.remoteParticipants['alice']?.videoTrackPublications
          .where((p) => p.sid == sid)
          .firstOrNull
          ?.track;
      if (track != null) {
        final view = rtc.RTCVideoRenderer();
        await view.initialize();
        view.srcObject = track.mediaStream;
        views.add(view);
        return track;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('Remote synthetic publication unavailable');
  }

  Future<int> frames(lk.RemoteVideoTrack track) async =>
      (await track.receiver!.getStats()).fold<int>(
        0,
        (sum, report) =>
            sum + ((report.values['framesDecoded'] as num?)?.toInt() ?? 0),
      );
  Future<int> advances(lk.RemoteVideoTrack track, int before) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(seconds: 15)) {
      final value = await frames(track);
      if (value > before + 5) return value;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw StateError('Encrypted synthetic frames stopped');
  }

  Future<lk.LocalTrackPublication<lk.LocalVideoTrack>> publish() async {
    final stream = MediaStreamWeb(
      canvas.callMethod<web.MediaStream>('captureStream'.toJS, 15.toJS),
      'local',
    );
    final track = lk.LocalVideoTrack(
      lk.TrackSource.camera,
      stream,
      stream.getVideoTracks().single,
      const lk.CameraCaptureOptions(),
    );
    try {
      return await alice.localParticipant!.publishVideoTrack(
        track,
        publishOptions: const lk.VideoPublishOptions(simulcast: false),
      );
    } catch (_) {
      await track.dispose();
      rethrow;
    }
  }

  try {
    await bob.connect(config['url'], config['bob']);
    await observer.connect(config['url'], config['observer']);
    await alice.connect(config['url'], config['alice']);
    final peer = alice.engine.publisher!.pc;
    final first = await publish();
    final firstRemote = await remote(bob, first.sid);
    final firstObserver = await remote(observer, first.sid);
    await Future<void>.delayed(const Duration(seconds: 2));
    final missing = await frames(firstRemote);
    await Future<void>.delayed(const Duration(seconds: 1));
    require(
      await frames(firstRemote) == missing,
      'Recipient decoded with no key',
    );
    await recipientKeys.setRawKey(initial, participantId: 'alice');
    final decoded = await advances(firstRemote, missing);
    await keys.setRawKey(prepared, participantId: 'alice', keyIndex: 1);
    require(
      await alice.e2eeManager!.getKeyIndex('alice') == 0,
      'Preparation changed active sender',
    );
    final stillOld = await advances(firstRemote, decoded);
    await alice.localParticipant!.removePublishedTrack(first.sid);
    final second = await publish();
    final secondRemote = await remote(bob, second.sid);
    final secondObserver = await remote(observer, second.sid);
    await Future<void>.delayed(const Duration(seconds: 2));
    final waiting = await frames(secondRemote);
    await Future<void>.delayed(const Duration(seconds: 1));
    require(
      await frames(secondRemote) == waiting,
      'New publication decoded before key delivery',
    );
    require(
      await alice.e2eeManager!.getKeyIndex('alice') == 1,
      'New sender index is incorrect',
    );
    await recipientKeys.setRawKey(
      prepared,
      participantId: 'alice',
      keyIndex: 1,
    );
    await bob.e2eeManager!.setKeyIndex(1, participantIdentity: 'alice');
    final committed = await advances(secondRemote, waiting);
    require(
      identical(alice.engine.publisher!.pc, peer),
      'Transport was recreated',
    );
    require(observer.e2eeManager == null, 'Observer has a decryptor');
    final observerInitial = await frames(firstObserver);
    final observerFinal = await frames(secondObserver);
    final reconnectEvents = alice.createListener();
    int reconnectedFrames;
    try {
      final reconnected = reconnectEvents.waitFor<lk.RoomReconnectedEvent>(
        duration: const Duration(seconds: 25),
      );
      await alice.sendSimulateScenario(fullReconnect: true);
      await reconnected;
      require(
        !identical(alice.engine.publisher!.pc, peer),
        'Full reconnect kept the old transport',
      );
      final third = alice.localParticipant!.videoTrackPublications.single;
      final thirdRemote = await remote(bob, third.sid);
      reconnectedFrames = await advances(
        thirdRemote,
        await frames(thirdRemote),
      );
    } finally {
      await reconnectEvents.dispose();
    }
    return {
      'platform': 'real browser SDK/worker and local SFU',
      'synthetic_canvas': true,
      'initial_missing_key_blocked': true,
      'initial_decoded_after_key': decoded,
      'old_sender_decoded_while_prepared': stillOld,
      'new_sender_key_index': 1,
      'new_publication_missing_key_blocked': true,
      'new_decoded_after_key': committed,
      'same_sender_transport': true,
      'observer_has_decryptor': false,
      'observer_initial_decoded_counter': observerInitial,
      'observer_final_decoded_counter': observerFinal,
      'full_reconnect_encrypted_frames': reconnectedFrames,
      'full_reconnect_recreated_sender_transport': true,
      'counter_alone_is_not_content_proof': true,
      'ratchet_defaults_changed': false,
      'physical_phone_tested': false,
      'media_saved': false,
    };
  } finally {
    timer.cancel();
    for (final view in views) {
      view.srcObject = null;
      await view.dispose();
    }
    await alice.dispose();
    await bob.dispose();
    await observer.dispose();
    await keys.keyProvider.dispose();
    await recipientKeys.keyProvider.dispose();
  }
}

class SdkPublicationFixture extends StatefulWidget {
  const SdkPublicationFixture({super.key});
  @override
  State<SdkPublicationFixture> createState() => _SdkPublicationFixtureState();
}

class _SdkPublicationFixtureState extends State<SdkPublicationFixture> {
  bool running = false;
  String result = 'Ready: synthetic video, real SDK encryption';
  Future<void> run() async {
    setState(() {
      running = true;
      result = 'Running SDK publication probe';
    });
    try {
      final proof = await probeBrowserPublication();
      if (mounted) {
        setState(
          () => result = 'PASS SDK_BROWSER_PUBLICATION ${jsonEncode(proof)}',
        );
      }
    } catch (error) {
      // Native/web SDK errors may contain the local token URL.
      if (mounted) setState(() => result = 'FAIL: ${error.runtimeType}');
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('SDK encrypted publication fixture')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        FilledButton(
          onPressed: running ? null : run,
          child: const Text('Run SDK publication probe'),
        ),
        const SizedBox(height: 16),
        Semantics(
          label: result,
          liveRegion: true,
          child: ExcludeSemantics(child: SelectableText(result)),
        ),
      ],
    ),
  );
}
