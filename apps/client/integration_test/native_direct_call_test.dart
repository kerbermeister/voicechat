// Real microphone, WebRTC and DTLS-SRTP on one Mac. Signalling stays in memory;
// this does not certify Matrix delivery, TURN or a second physical device.
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart' as mx;
// ignore: implementation_imports
import 'package:matrix/src/voip/models/call_options.dart';
// ignore: implementation_imports
import 'package:matrix/src/voip/models/voip_id.dart';
import 'package:voicechat_probe/direct_call.dart';
import '../test/chat_actions_test.dart' show OutboxDatabase;

class NativeDelegate extends Fake implements mx.WebRTCDelegate {
  @override
  get mediaDevices => rtc.navigator.mediaDevices;
  @override
  bool get isWeb => false;
  @override
  Future<void> stopRingtone() async {}
  @override
  Future<void> handleCallEnded(mx.CallSession call) async {}
  @override
  Future<void> handleMissedCall(mx.CallSession call) async {}
  @override
  Future<rtc.RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> config, [
    Map<String, dynamic> constraints = const {},
  ]) => rtc.createPeerConnection(config, constraints);
}

class NativeVoip extends Fake implements mx.VoIP {
  NativeVoip(this.name, {NativeDelegate? delegate})
    : delegate = delegate ?? NativeDelegate();
  final String name;
  @override
  final NativeDelegate delegate;
  @override
  final calls = <VoipId, mx.CallSession>{};
  @override
  final incomingCallRoomId = <String, String>{};
  @override
  VoipId? currentCID;
  @override
  mx.CallTimeouts? timeouts = mx.CallTimeouts();
  @override
  mx.CallParticipant get localParticipant =>
      mx.CallParticipant(this, userId: '@$name:local', deviceId: name);
}

class LocalSession extends mx.CallSession {
  LocalSession(super.opts);
  late LocalSession peer;
  String wireSdp(String sdp) => sdp;
  final invited = Completer<void>();
  @override
  Future<String?> sendInviteToCall(
    mx.Room room,
    String callId,
    int lifetime,
    String partyId,
    String sdp, {
    String type = 'offer',
    String version = '1',
    String? txid,
    mx.CallCapabilities? capabilities,
    mx.SDPStreamMetadata? metadata,
  }) async {
    await peer.initWithInvite(
      RegExp(r'^m=video ', multiLine: true).hasMatch(sdp)
          ? mx.CallType.kVideo
          : mx.CallType.kVoice,
      rtc.RTCSessionDescription(wireSdp(sdp), type),
      metadata,
      lifetime,
      false,
    );
    if (!invited.isCompleted) invited.complete();
    return 'invite';
  }

  @override
  Future<String?> sendAnswerCall(
    mx.Room room,
    String callId,
    String sdp,
    String partyId, {
    String type = 'answer',
    String version = '1',
    String? txid,
    mx.CallCapabilities? capabilities,
    mx.SDPStreamMetadata? metadata,
  }) async {
    await peer.onAnswerReceived(
      rtc.RTCSessionDescription(wireSdp(sdp), type),
      metadata,
    );
    return 'answer';
  }

  @override
  Future<String?> sendSelectCallAnswer(
    mx.Room room,
    String callId,
    String partyId,
    String selected, {
    String version = '1',
    String? txid,
  }) async => 'selected';
  @override
  Future<String?> sendCallCandidates(
    mx.Room room,
    String callId,
    String partyId,
    List<Map<String, dynamic>> candidates, {
    String version = '1',
    String? txid,
  }) async {
    await peer.onCandidatesReceived(candidates);
    return 'candidates';
  }

  @override
  Future<String?> sendSDPStreamMetadataChanged(
    mx.Room room,
    String callId,
    String partyId,
    mx.SDPStreamMetadata metadata, {
    String version = '1',
    String? txid,
  }) async {
    if (!peer.callHasEnded) await peer.onSDPStreamMetadataReceived(metadata);
    return 'metadata';
  }

  @override
  Future<String?> sendCallNegotiate(
    mx.Room room,
    String callId,
    int lifetime,
    String partyId,
    String sdp, {
    String type = 'offer',
    String version = '1',
    String? txid,
    mx.CallCapabilities? capabilities,
    mx.SDPStreamMetadata? metadata,
  }) async {
    if (!peer.callHasEnded) {
      await peer.onNegotiateReceived(
        metadata,
        rtc.RTCSessionDescription(wireSdp(sdp), type),
      );
    }
    return 'negotiate';
  }

  @override
  Future<String?> sendHangupCall(
    mx.Room room,
    String callId,
    String partyId,
    String? cause, {
    String version = '1',
    String? txid,
  }) async {
    if (!peer.callHasEnded) {
      await peer.terminate(
        mx.CallParty.kRemote,
        mx.CallErrorCode.userHangup,
        true,
      );
    }
    return 'hangup';
  }
}

Future<void> until(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 20)) {
      throw TimeoutException('Native call state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Repeated native direct acceptance, media and remote hangup',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('Локальная проверка соединения звонков')),
          ),
        ),
      );
      final client = mx.Client(
        'isolated-native-call',
        database: OutboxDatabase(),
      );
      for (var cycle = 0; cycle < 3; cycle++) {
        LocalSession make(String name, mx.CallDirection direction) =>
            LocalSession(
              CallOptions(
                callId: 'local-$cycle',
                type: mx.CallType.kVoice,
                dir: direction,
                localPartyId: name,
                voip: NativeVoip(name),
                room: mx.Room(client: client, id: '!local:local'),
                iceServers: [],
              ),
            );
        final caller = make('caller', mx.CallDirection.kOutgoing);
        final callee = make('callee', mx.CallDirection.kIncoming);
        caller.peer = callee;
        callee.peer = caller;
        caller.remoteUserId = '@callee:local';
        callee.remoteUserId = '@caller:local';
        final local = DirectCall(caller, () {}, debugPrint);
        final remote = DirectCall(callee, () {}, debugPrint);
        // Avoid audible loopback/feedback; packets still traverse real WebRTC.
        final subscriptions = [caller, callee]
            .map(
              (session) => session.onStreamAdd.stream.listen((stream) {
                if (!stream.isLocal()) {
                  for (final track in stream.stream!.getAudioTracks()) {
                    track.enabled = false;
                  }
                }
              }),
            )
            .toList();
        try {
          await caller.initOutboundCall(mx.CallType.kVoice);
          await caller.invited.future.timeout(const Duration(seconds: 20));
          if (cycle == 1) {
            await local.close();
            await until(() => remote.isClosed);
            expect(callee.localUserMediaStream, isNull);
          } else {
            await callee.answer();
            await until(
              () =>
                  caller.state == mx.CallState.kConnected &&
                  callee.state == mx.CallState.kConnected,
            );
            var received = 0;
            for (var i = 0; i < 30 && received == 0; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
              received = await remote.receivedAudioPackets();
            }
            expect(received, greaterThan(0));
            final stats = await caller.pc!.getStats();
            expect(
              stats.any(
                (s) =>
                    s.type == 'transport' &&
                    s.values['dtlsState'] == 'connected',
              ),
              true,
            );
            await local.close();
            await until(() => remote.isClosed);
          }
          debugPrint(
            'PASS: native call cycle $cycle; remote ended; ${cycle == 1 ? "cancel before answer" : "accept, audio packets and DTLS"}',
          );
        } finally {
          await Future.wait([local.close(), remote.close()]);
          for (final subscription in subscriptions) {
            await subscription.cancel();
          }
        }
      }
    },
    skip:
        !Platform.isMacOS || !const bool.fromEnvironment('HARDWARE_CALL_TEST'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
