import 'dart:async';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
// The delegate uses the base interface, not flutter_webrtc's static facade.
// ignore: depend_on_referenced_packages
import 'package:webrtc_interface/webrtc_interface.dart' show MediaDevices;
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/voip/models/call_options.dart';
// ignore: implementation_imports
import 'package:matrix/src/voip/models/voip_id.dart';
import 'package:voicechat_probe/call_controller.dart';
import 'package:voicechat_probe/direct_call.dart';
import 'chat_actions_test.dart' show OutboxDatabase;
import 'direct_call_media_test.dart' show MediaTrack, MediaStream;

class Peer extends Fake implements rtc.RTCPeerConnection {
  @override
  void Function(rtc.RTCPeerConnectionState)? onConnectionState;
  @override
  void Function(rtc.RTCIceConnectionState)? onIceConnectionState;
  @override
  void Function(rtc.RTCIceGatheringState)? onIceGatheringState;
  @override
  void Function(rtc.RTCIceCandidate)? onIceCandidate;
  @override
  void Function(rtc.RTCTrackEvent)? onTrack;
  @override
  void Function()? onRenegotiationNeeded;
  int nativeRestarts = 0;
  @override
  Future<void> restartIce() async {
    nativeRestarts++;
  }

  rtc.RTCSessionDescription? remote;
  Completer<void>? localDescription;
  bool connectDuringDescription = false;
  final candidates = <String>[];
  @override
  Future<void> setRemoteDescription(rtc.RTCSessionDescription sdp) async {
    remote = sdp;
  }

  @override
  Future<rtc.RTCSessionDescription?> getRemoteDescription() async => remote;
  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription sdp) async {
    if (connectDuringDescription) {
      onIceConnectionState?.call(
        rtc.RTCIceConnectionState.RTCIceConnectionStateCompleted,
      );
    }
    await localDescription?.future;
  }

  @override
  Future<rtc.RTCSessionDescription> createAnswer([
    Map<String, dynamic> constraints = const {},
  ]) async => rtc.RTCSessionDescription('sdp', 'answer');
  @override
  Future<void> addCandidate(rtc.RTCIceCandidate candidate) async {
    candidates.add(candidate.candidate!);
  }

  @override
  Future<void> close() async {}
  @override
  Future<void> dispose() async {}
}

class Capture extends Fake implements MediaDevices {
  late final requested = Completer<void>();
  late final result = Completer<rtc.MediaStream>();
  @override
  Future<rtc.MediaStream> getUserMedia(Map<String, dynamic> constraints) {
    if (!requested.isCompleted) requested.complete();
    return result.future;
  }
}

class Delegate extends Fake implements WebRTCDelegate {
  final peer = Peer();
  @override
  final Capture mediaDevices = Capture();
  Completer<void>? ending;
  @override
  Future<void> stopRingtone() async {}
  @override
  Future<void> handleCallEnded(CallSession call) async {
    await ending?.future;
  }

  @override
  Future<rtc.RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> config, [
    Map<String, dynamic> constraints = const {},
  ]) async => peer;
}

class ProtocolVoip extends Fake implements VoIP {
  Completer<List<Map<String, dynamic>>>? servers;
  @override
  Future<List<Map<String, dynamic>>> getIceServers() async =>
      await servers?.future ?? [];
  @override
  final Delegate delegate = Delegate();
  @override
  final calls = <VoipId, CallSession>{};
  @override
  final incomingCallRoomId = <String, String>{};
  @override
  VoipId? currentCID;
  @override
  CallTimeouts? timeouts = CallTimeouts();
}

class ProtocolStream extends MediaStream {
  bool disposed = false;
  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class Session extends CallSession {
  Session(super.opts);
  int answers = 0;
  int hangups = 0;
  int restarts = 0;
  bool nativeRestart = false;
  bool failCandidates = false;
  final sentCandidates = <List<String>>[];
  final captured = <rtc.MediaStream>[];
  Completer<void>? cleanup;
  @override
  Future<void> addLocalStream(
    rtc.MediaStream stream,
    String purpose, {
    bool addToPeerConnection = true,
  }) async {
    captured.add(stream);
  }

  @override
  Future<void> updateMuteStatus() async {}
  @override
  Future<void> restartIce() async {
    restarts++;
    if (nativeRestart) await super.restartIce();
  }

  @override
  Future<String?> sendCallCandidates(
    Room room,
    String callId,
    String partyId,
    List<Map<String, dynamic>> candidates, {
    String version = '1',
    String? txid,
  }) async {
    sentCandidates.add(
      candidates.map((c) => c['candidate'] as String).toList(),
    );
    if (failCandidates) {
      failCandidates = false;
      throw StateError('temporary transport failure');
    }
    return 'candidates';
  }

  @override
  Future<void> cleanUp() async {
    await cleanup?.future;
    await super.cleanUp();
  }

  @override
  Future<String?> sendAnswerCall(
    Room room,
    String callId,
    String sdp,
    String partyId, {
    String type = 'answer',
    String version = '1',
    String? txid,
    CallCapabilities? capabilities,
    SDPStreamMetadata? metadata,
  }) async {
    answers++;
    return 'answer';
  }

  @override
  Future<String?> sendHangupCall(
    Room room,
    String callId,
    String partyId,
    String? cause, {
    String version = '1',
    String? txid,
  }) async {
    hangups++;
    return 'hangup';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Client client;
  late ProtocolVoip voip;
  late Session session;
  setUp(() {
    client = Client('protocol', database: OutboxDatabase());
    voip = ProtocolVoip();
    session = Session(
      CallOptions(
        callId: 'test',
        type: CallType.kVoice,
        dir: CallDirection.kIncoming,
        localPartyId: 'local',
        voip: voip,
        room: Room(client: client, id: '!test:local'),
        iceServers: [],
      ),
    );
  });
  tearDown(() async {
    await session.cleanUp();
    await client.dispose();
  });
  Future<void> incoming() => session.initWithInvite(
    CallType.kVoice,
    rtc.RTCSessionDescription('offer', 'offer'),
    null,
    60000,
    false,
  );

  test(
    'Hangup is sent before slow cleanup and delegate/history, only once',
    () async {
      session.cleanup = Completer<void>();
      voip.delegate.ending = Completer<void>();
      final closing = session.hangup(reason: CallErrorCode.userHangup);
      await Future<void>.delayed(Duration.zero);
      expect(session.hangups, 1);
      expect(session.callHasEnded, true);
      await session.hangup(reason: CallErrorCode.userHangup);
      expect(session.hangups, 1);
      session.cleanup!.complete();
      voip.delegate.ending!.complete();
      await closing;
    },
  );
  test(
    'Cancellation during permission releases late capture without answering',
    () async {
      await incoming();
      final answering = session.answer();
      await voip.delegate.mediaDevices.requested.future;
      await session.hangup(reason: CallErrorCode.userHangup);
      final media = ProtocolStream();
      voip.delegate.mediaDevices.result.complete(media);
      await answering;
      expect(media.disposed, true);
      expect((media.tracks.single as MediaTrack).stopped, true);
      expect(session.captured, isEmpty);
      expect(session.answers, 0);
      session.setCallState(CallState.kConnecting);
      voip.delegate.peer.onIceConnectionState?.call(
        rtc.RTCIceConnectionState.RTCIceConnectionStateCompleted,
      );
      expect(session.state, CallState.kEnded);
    },
  );
  testWidgets(
    'Candidates received during answer are applied; completed ICE cannot regress',
    (tester) async {
      await incoming();
      final peer = voip.delegate.peer..connectDuringDescription = true;
      voip.delegate.mediaDevices.result.complete(ProtocolStream());
      final answering = session.answer();
      await tester.pump();
      await session.onCandidatesReceived([
        {
          'candidate': 'candidate:1 1 udp 2122260223 192.0.2.1 5000 typ host',
          'sdpMid': '0',
          'sdpMLineIndex': 0,
        },
      ]);
      expect(peer.candidates, hasLength(1));
      await session.answer(); // double acceptance must not send a second answer
      await tester.pump(const Duration(milliseconds: 200));
      await answering;
      expect(session.answers, 1);
      expect(session.state, CallState.kConnected);
      await tester.pump(const Duration(seconds: 31));
      expect(session.hangups, 0);
      await session.hangup(reason: CallErrorCode.userHangup);
    },
  );
  testWidgets(
    'A failed ICE send preserves candidates and retries with later arrivals',
    (tester) async {
      await incoming();
      final peer = voip.delegate.peer;
      session.failCandidates = true;
      peer.onIceCandidate!(rtc.RTCIceCandidate('first', '0', 0));
      voip.delegate.mediaDevices.result.complete(ProtocolStream());
      final answering = session.answer();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await answering;
      expect(session.sentCandidates, [
        ['first'],
      ]);
      peer.onIceCandidate!(rtc.RTCIceCandidate('later', '0', 0));
      await tester.pump(const Duration(seconds: 1));
      expect(session.sentCandidates.last, ['first', 'later']);
      peer.onIceCandidate!(rtc.RTCIceCandidate('after-recovery', '0', 0));
      await tester.pump(const Duration(milliseconds: 500));
      expect(session.sentCandidates.last, ['after-recovery']);
      await session.hangup(reason: CallErrorCode.userHangup);
    },
  );
  testWidgets(
    'Cancel during SDP prevents late answer and connection watchdog',
    (tester) async {
      await incoming();
      voip.delegate.peer.localDescription = Completer<void>();
      voip.delegate.mediaDevices.result.complete(ProtocolStream());
      final answer = session.answer();
      await tester.pump();
      await session.hangup(reason: CallErrorCode.userHangup);
      voip.delegate.peer.localDescription!.complete();
      await answer;
      await tester.pump(const Duration(seconds: 31));
      expect(session.answers, 0);
      expect(session.hangups, 1);
    },
  );
  testWidgets(
    'Initial connection and interrupted transport have bounded waits',
    (tester) async {
      await incoming();
      session.setCallState(CallState.kConnecting);
      await tester.pump(const Duration(seconds: 30));
      expect(session.hangups, 1);
      expect(session.callHasEnded, true);
    },
  );
  testWidgets(
    'Transient disconnect recovers, permanent loss ends after 15 seconds',
    (tester) async {
      await incoming();
      final ice = voip.delegate.peer.onIceConnectionState!;
      ice(rtc.RTCIceConnectionState.RTCIceConnectionStateConnected);
      ice(rtc.RTCIceConnectionState.RTCIceConnectionStateDisconnected);
      await tester.pump(const Duration(seconds: 10));
      ice(rtc.RTCIceConnectionState.RTCIceConnectionStateCompleted);
      await tester.pump(const Duration(seconds: 20));
      expect(session.hangups, 0);
      ice(rtc.RTCIceConnectionState.RTCIceConnectionStateDisconnected);
      await tester.pump(const Duration(seconds: 15));
      expect(session.hangups, 1);
      expect(session.restarts, 2);
    },
  );
  for (final state in [
    rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed,
    rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed,
    rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
  ]) {
    testWidgets('Remote transport loss $state ends without a Matrix hangup', (
      tester,
    ) async {
      await incoming();
      session.setCallState(CallState.kConnected);
      voip.delegate.peer.onConnectionState!(state);
      await tester.pump(const Duration(seconds: 15));
      expect(session.hangups, 1);
      expect(session.callHasEnded, true);
      voip.delegate.peer.onConnectionState!(
        rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      expect(session.callHasEnded, true);
    });
  }
  testWidgets('Failed transport can recover before its bounded deadline', (
    tester,
  ) async {
    await incoming();
    session.setCallState(CallState.kConnected);
    final connection = voip.delegate.peer.onConnectionState!;
    connection(rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed);
    voip.delegate.peer.onIceConnectionState!(
      rtc.RTCIceConnectionState.RTCIceConnectionStateFailed,
    );
    await tester.pump(const Duration(seconds: 5));
    expect(session.hangups, 0);
    expect(
      session.restarts,
      1,
      reason: 'ICE and DTLS callbacks coalesce one recovery',
    );
    connection(rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected);
    await tester.pump(const Duration(seconds: 20));
    expect(session.hangups, 0);
    await session.hangup(reason: CallErrorCode.userHangup);
  });
  for (final recovered in [false, true]) {
    testWidgets(
      'A delayed TURN refresh respects recovered transport: $recovered',
      (tester) async {
        await incoming();
        session.nativeRestart = true;
        session.setCallState(CallState.kConnected);
        voip.servers = Completer<List<Map<String, dynamic>>>();
        final peer = voip.delegate.peer;
        peer.onConnectionState!(
          rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed,
        );
        await tester.pump(const Duration(seconds: 2));
        if (recovered) {
          peer.onConnectionState!(
            rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected,
          );
        }
        voip.servers!.complete([]);
        await tester.pump();
        expect(peer.nativeRestarts, recovered ? 0 : 1);
        expect(session.hangups, 0);
        await session.hangup(reason: CallErrorCode.userHangup);
      },
    );
  }
  testWidgets('Recovered DTLS transport cancels disconnect deadline', (
    tester,
  ) async {
    await incoming();
    session.setCallState(CallState.kConnected);
    final connection = voip.delegate.peer.onConnectionState!;
    connection(rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected);
    await tester.pump(const Duration(seconds: 5));
    connection(rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected);
    await tester.pump(const Duration(seconds: 15));
    expect(session.hangups, 0);
    await session.hangup(reason: CallErrorCode.userHangup);
  });
  test(
    'Application exit waits for the same in-progress direct teardown',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Event'),
        (_) async => null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Event'),
          null,
        ),
      );
      final calls = CallController(
        client,
        'http://localhost',
        'ws://localhost',
        (_) {},
      );
      final call = DirectCall(session, () {}, (_) {});
      calls.active = call;
      session.cleanup = Completer<void>();
      final closing = call.close();
      var exited = false;
      final exit = calls.didRequestAppExit().then((value) {
        exited = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(exited, false);
      expect(session.hangups, 1);
      session.cleanup!.complete();
      await closing;
      expect(await exit, AppExitResponse.exit);
    },
  );
  test(
    'Mac window close ends its call while the controller can receive another',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Event'),
        (_) async => null,
      );
      final calls = CallController(
        client,
        'http://localhost',
        'ws://localhost',
        (_) {},
      );
      calls.active = DirectCall(session, () {}, (_) {});
      try {
        final replied = Completer<void>();
        await messenger.handlePlatformMessage(
          'voicechat/calls',
          const StandardMethodCodec().encodeMethodCall(const MethodCall('end')),
          (bytes) {
            const StandardMethodCodec().decodeEnvelope(bytes!);
            replied.complete();
          },
        );
        await replied.future;
        expect(session.hangups, 1);
        expect(calls.active!.isClosed, true);
        expect(calls.canHandleNewCall, true);
      } finally {
        await calls.close();
        messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Event'),
          null,
        );
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
  test('Application exit remains bounded when cleanup cannot finish', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Event'),
      (_) async => null,
    );
    final calls = CallController(
      client,
      'http://localhost',
      'ws://localhost',
      (_) {},
    );
    calls.active = DirectCall(session, () {}, (_) {});
    session.cleanup = Completer<void>();
    final exit = calls.didRequestAppExit();
    await Future<void>.delayed(Duration.zero);
    expect(session.hangups, 1);
    expect(await exit, AppExitResponse.exit);
    session.cleanup!.complete();
    await calls.close();
    messenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Event'),
      null,
    );
  });
}
