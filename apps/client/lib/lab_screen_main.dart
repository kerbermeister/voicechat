// Одноразовая лаборатория SS-01; не является частью распространяемого клиента.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'screen_capture.dart';

SemanticsHandle? probeSemantics;
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  probeSemantics = SemanticsBinding.instance.ensureSemantics();
  runApp(const MaterialApp(home: ScreenProbe()));
}

class ScreenProbe extends StatefulWidget {
  const ScreenProbe({super.key});
  @override
  State<ScreenProbe> createState() => _ScreenProbeState();
}

class _ScreenProbeState extends State<ScreenProbe> {
  final rooms = <lk.Room>[];
  final keys = <lk.BaseKeyProvider>[];
  final listeners = <lk.EventsListener<lk.RoomEvent>>[];
  final peers = <rtc.RTCPeerConnection>[];
  rtc.MediaStream? directStream;
  final directRenderer = rtc.RTCVideoRenderer();
  Map<String, dynamic>? fixture;
  String stage = 'loading';
  bool busy = false;
  bool decrypted = false;
  String? savedToken;
  ScreenCapture? screenCapture;
  final role = Uri.base.queryParameters['role'] ?? 'viewer';

  @override
  void initState() {
    super.initState();
    unawaited(prepare());
  }

  Future<void> perform(Future<void> Function() operation) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await operation();
    } catch (error) {
      // Не печатаем исключения SDK: они могут содержать одноразовые JWT.
      stage = 'failed:${error.runtimeType}';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> prepare() => perform(() async {
    final response = await http.get(Uri.base.resolve('fixture.json'));
    if (response.statusCode != 200) throw StateError('fixture unavailable');
    fixture = jsonDecode(response.body) as Map<String, dynamic>;
    for (final channel in ['screen', 'camera']) {
      final provider = await lk.BaseKeyProvider.create(
        sharedKey: false,
        discardFrameWhenCryptorNotReady: true,
      );
      keys.add(provider);
      // Ключи только тестовые. Эта лаборатория проверяет cryptor, не Matrix key exchange.
      if (role != 'wrong') {
        await provider.setRawKey(
          Uint8List.fromList(base64Decode(fixture!['key'] as String)),
          participantId: 'sender',
        );
      }
      final room = lk.Room(
        roomOptions: lk.RoomOptions(
          encryption: lk.E2EEOptions(keyProvider: provider),
          adaptiveStream: false,
          dynacast: false,
        ),
      );
      rooms.add(room);
      final listener = room.createListener();
      listeners.add(listener);
      listener.on<lk.TrackSubscribedEvent>((_) {
        if (mounted) setState(() {});
      });
      listener.on<lk.TrackE2EEStateEvent>((event) {
        if (channel == 'screen' && event.state == lk.E2EEState.kOk) {
          decrypted = true;
        }
      });
      await room.connect(
        'ws://localhost:7880',
        fixture!['${channel}_$role'] as String,
      );
    }
    if (role == 'sender') {
      await rooms[1].localParticipant!.setCameraEnabled(true);
      await rooms[1].localParticipant!.setMicrophoneEnabled(true);
      await prepareDirect();
    }
    stage = 'ready';
  });

  Future<void> prepareDirect() async {
    await directRenderer.initialize();
    final sender = await rtc.createPeerConnection({'iceServers': []});
    final receiver = await rtc.createPeerConnection({'iceServers': []});
    peers.addAll([sender, receiver]);
    final candidates = <rtc.RTCIceCandidate>[];
    final answers = <rtc.RTCIceCandidate>[];
    sender.onIceCandidate = candidates.add;
    receiver.onIceCandidate = answers.add;
    receiver.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        directRenderer.srcObject = event.streams.first;
      }
    };
    directStream = await rtc.navigator.mediaDevices.getUserMedia({
      'video': true,
      'audio': true,
    });
    for (final track in directStream!.getTracks()) {
      await sender.addTrack(track, directStream!);
    }
    final offer = await sender.createOffer();
    await sender.setLocalDescription(offer);
    await receiver.setRemoteDescription(offer);
    final answer = await receiver.createAnswer();
    await receiver.setLocalDescription(answer);
    await sender.setRemoteDescription(answer);
    // Одноразовая локальная пара проверяет сосуществование SDK, не Matrix-сигналинг.
    for (var i = 0; i < 50; i++) {
      while (candidates.isNotEmpty) {
        await receiver.addCandidate(candidates.removeAt(0));
      }
      while (answers.isNotEmpty) {
        await sender.addCandidate(answers.removeAt(0));
      }
      if (sender.connectionState ==
          rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('local P2P did not connect');
  }

  Future<void> capture() => perform(() async {
    // Вызов до первого сетевого await сохраняет browser user activation.
    screenCapture = await ScreenCapture.start();
    final track = await screenCapture!.publication();
    try {
      if (track.mediaStream.getAudioTracks().isNotEmpty) {
        throw StateError('unexpected screen audio');
      }
      await rooms.first.localParticipant!.publishVideoTrack(track);
      stage = 'published';
    } catch (_) {
      await track.stop();
      await track.dispose();
      await screenCapture?.close();
      rethrow;
    }
  });

  Future<void> replaceClone() => perform(() async {
    final participant = rooms.first.localParticipant!;
    await participant.removePublishedTrack(
      participant.videoTrackPublications.single.sid,
    );
    await participant.publishVideoTrack(await screenCapture!.publication());
    stage = 'clone-republished';
  });

  Future<void> wrongSource() => perform(() async {
    final camera = await lk.LocalVideoTrack.createCameraTrack();
    try {
      await rooms.first.localParticipant!.publishVideoTrack(camera);
      stage = 'camera-published';
    } catch (_) {
      stage = 'camera-rejected';
    } finally {
      await camera.dispose();
    }
  });

  Future<void> wrongKey() => perform(() async {
    await keys.first.setRawKey(Uint8List(32), participantId: 'sender');
    stage = 'wrong-key-installed';
  });

  Future<int> frames(lk.Room room) async {
    var count = 0;
    for (final peer in room.remoteParticipants.values) {
      for (final publication in peer.videoTrackPublications) {
        final stats = await publication.track?.receiver?.getStats() ?? [];
        for (final stat in stats) {
          if (stat.type == 'inbound-rtp') {
            count += (stat.values['framesDecoded'] as num? ?? 0).toInt();
          }
        }
      }
    }
    return count;
  }

  Future<void> inspect() => perform(() async {
    final screen = await frames(rooms.first);
    final camera = await frames(rooms[1]);
    var audio = 0;
    for (final participant in rooms[1].remoteParticipants.values) {
      for (final publication in participant.audioTrackPublications) {
        for (final stat
            in await publication.track?.receiver?.getStats() ?? []) {
          if (stat.type == 'inbound-rtp') {
            audio += (stat.values['packetsReceived'] as num? ?? 0).toInt();
          }
        }
      }
    }
    var direct = 0;
    if (peers.isNotEmpty) {
      for (final stat in await peers.last.getStats()) {
        if (stat.type == 'inbound-rtp') {
          direct += (stat.values['framesDecoded'] as num? ?? 0).toInt();
        }
      }
    }
    stage =
        'stats:screen=$screen,camera=$camera,decrypted=$decrypted,p2p=$direct,publications=${rooms.first.localParticipant!.videoTrackPublications.length},audio=$audio';
  });

  Future<void> rememberToken() => perform(() async {
    // Только лаборатория: public API SDK не выдаёт обновлённый JWT для replay-теста.
    // ignore: invalid_use_of_internal_member
    savedToken = rooms.first.engine.token;
    stage = savedToken != fixture!['screen_sender']
        ? 'token-refreshed'
        : 'token-original';
  });

  Future<void> duplicateTrack() => perform(() async {
    final original =
        rooms.first.localParticipant!.videoTrackPublications.first.track
            as lk.LocalVideoTrack;
    final stream = await original.mediaStream.clone();
    // Только негативная лабораторная проверка: public factory открывает новый picker.
    // ignore: invalid_use_of_internal_member
    final duplicate = lk.LocalVideoTrack(
      lk.TrackSource.screenShareVideo,
      stream,
      stream.getVideoTracks().single,
      original.currentOptions,
    );
    try {
      await rooms.first.localParticipant!.publishVideoTrack(duplicate);
      stage = 'duplicate-published';
    } catch (_) {
      await duplicate.stop();
      await duplicate.dispose();
      stage = 'duplicate-rejected';
    }
  });

  Future<void> replay() => perform(() async {
    final room = lk.Room();
    try {
      await room.connect('ws://localhost:7880', savedToken!);
      stage = 'replay-accepted';
    } on lk.ConnectException {
      stage = 'replay-rejected';
    } finally {
      await room.dispose();
    }
  });

  @override
  void dispose() {
    unawaited(screenCapture?.close());
    for (final peer in peers) {
      unawaited(peer.close());
    }
    for (final track in directStream?.getTracks() ?? <rtc.MediaStreamTrack>[]) {
      unawaited(track.stop());
    }
    unawaited(directStream?.dispose());
    unawaited(directRenderer.dispose());
    for (final listener in listeners) {
      unawaited(listener.dispose());
    }
    for (final room in rooms) {
      unawaited(room.dispose());
    }
    for (final provider in keys) {
      unawaited(provider.keyProvider.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text(stage),
        if (role == 'sender') ...[
          TextButton(
            onPressed: busy ? null : wrongSource,
            child: const Text('Камера в screen room'),
          ),
          TextButton(
            onPressed: busy ? null : replaceClone,
            child: const Text('Перепубликовать копию'),
          ),
          TextButton(
            onPressed: busy ? null : duplicateTrack,
            child: const Text('Второй трек'),
          ),
          TextButton(
            onPressed: busy ? null : rememberToken,
            child: const Text('Запомнить токен'),
          ),
          TextButton(
            onPressed: busy || savedToken == null ? null : replay,
            child: const Text('Повторить токен'),
          ),
        ],
        if (peers.isNotEmpty)
          SizedBox(
            width: 160,
            height: 90,
            child: rtc.RTCVideoView(directRenderer),
          ),
        TextButton(
          onPressed: busy ? null : inspect,
          child: const Text('Статистика'),
        ),
        if (role == 'wrong')
          TextButton(
            onPressed: busy ? null : wrongKey,
            child: const Text('Неверный ключ'),
          ),
        if (role == 'viewer')
          TextButton(
            onPressed: busy ? null : capture,
            child: const Text('Публикация viewer'),
          ),
        if (role == 'sender')
          TextButton(
            onPressed: busy ? null : capture,
            child: const Text('Захватить экран'),
          ),
        for (final room in rooms)
          for (final peer in room.remoteParticipants.values)
            for (final publication in peer.videoTrackPublications)
              if (publication.track case lk.VideoTrack track)
                SizedBox(
                  width: 480,
                  height: 240,
                  child: lk.VideoTrackRenderer(track),
                ),
      ],
    ),
  );
}
