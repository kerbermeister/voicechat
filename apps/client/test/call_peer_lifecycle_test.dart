// Real CallSession async setup, synthetic peer/capture; no devices or network.
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/voip/models/call_options.dart';
import 'chat_actions_test.dart' show OutboxDatabase;
import 'direct_call_protocol_test.dart'
    show Delegate, Peer, ProtocolVoip, ProtocolStream, Session;

class _Database extends OutboxDatabase {
  @override
  Future<void> close() async {}
}

class _LateDelegate extends Delegate {
  final started = Completer<void>();
  final ready = Completer<rtc.RTCPeerConnection>();
  @override
  Future<rtc.RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> config, [
    Map<String, dynamic> constraints = const {},
  ]) {
    started.complete();
    return ready.future;
  }
}

class _Voip extends ProtocolVoip {
  final _late = _LateDelegate();
  @override
  _LateDelegate get delegate => _late;
}

class _OwnedPeer extends Peer {
  int closes = 0, disposals = 0;
  bool failDescription = false;
  @override
  Future<void> setRemoteDescription(rtc.RTCSessionDescription sdp) async {
    if (failDescription) throw StateError('Synthetic SDP setup failure');
    await super.setRemoteDescription(sdp);
  }

  @override
  Future<void> close() async {
    closes++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

void main() {
  for (final scenario in [
    'incoming_cancel',
    'outgoing_cancel',
    'outgoing_failure',
    'incoming_sdp_failure',
  ]) {
    test('Peer setup does not outlive call: $scenario', () async {
      final client = Client('peer-lifecycle', database: _Database());
      final voip = _Voip();
      final incoming = scenario.startsWith('incoming');
      final session = Session(
        CallOptions(
          callId: 'late',
          type: CallType.kVoice,
          dir: incoming ? CallDirection.kIncoming : CallDirection.kOutgoing,
          localPartyId: 'local',
          voip: voip,
          room: Room(client: client, id: '!late:fixture'),
          iceServers: [],
        ),
      );
      final peer = _OwnedPeer();
      final action =
          (incoming
                  ? session.initWithInvite(
                      CallType.kVoice,
                      rtc.RTCSessionDescription('offer', 'offer'),
                      null,
                      60000,
                      false,
                    )
                  : session.initOutboundCall(CallType.kVoice))
              .then<Object?>((_) => null, onError: (Object error) => error);
      try {
        await voip.delegate.started.future;
        if (scenario == 'outgoing_failure') {
          voip.delegate.ready.completeError(
            StateError('Synthetic peer creation failure'),
          );
        } else if (scenario == 'incoming_sdp_failure') {
          peer.failDescription = true;
          voip.delegate.ready.complete(peer);
        } else {
          await session.hangup(reason: CallErrorCode.userHangup);
          voip.delegate.ready.complete(peer);
        }
        await Future<void>.delayed(Duration.zero);
        final captureRequested =
            voip.delegate.mediaDevices.requested.isCompleted;
        if (captureRequested) {
          voip.delegate.mediaDevices.result.complete(ProtocolStream());
        }
        final error = await action;
        // ignore: avoid_print
        print(
          'CALL_PEER_LIFECYCLE ${jsonEncode({'scenario': scenario, 'capture_requested': captureRequested, 'ended': session.callHasEnded, 'late_peer_disposed': peer.disposals, 'error_propagated': error != null})}',
        );
        expect(
          captureRequested,
          isFalse,
          reason: 'A cancelled/failed setup must not request a microphone',
        );
        expect(session.callHasEnded, isTrue);
        if (scenario.endsWith('failure')) {
          expect(error, isStateError);
          if (incoming) expect(peer.disposals, 1);
        } else {
          expect(error, isNull);
          expect(peer.closes, 1);
          expect(peer.disposals, 1);
        }
      } finally {
        if (!voip.delegate.ready.isCompleted) {
          voip.delegate.ready.complete(peer);
        }
        await session.terminate(
          CallParty.kLocal,
          CallErrorCode.userHangup,
          false,
        );
        await client.dispose();
      }
    });
  }
}
