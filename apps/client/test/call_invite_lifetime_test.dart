// Real CallSession timers; synthetic RTC factory, no device or network.
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/voip/models/call_options.dart';
import 'call_window_test.dart' show WindowDatabase;
import 'direct_call_protocol_test.dart'
    show Delegate, Peer, ProtocolVoip, Session;

class _DelayedDelegate extends Delegate {
  final ready = Completer<rtc.RTCPeerConnection>();
  @override
  Future<rtc.RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> config, [
    Map<String, dynamic> constraints = const {},
  ]) => ready.future;
}

class _DelayedVoip extends ProtocolVoip {
  final _delayed = _DelayedDelegate();
  @override
  _DelayedDelegate get delegate => _delayed;
}

class _Peer extends Peer {
  int disposals = 0;
  @override
  Future<void> dispose() async {
    disposals++;
  }
}

void main() {
  for (final scenario in [
    'remaining',
    'local_cap',
    'already_expired',
    'slow_peer',
  ]) {
    testWidgets('Incoming invite lifetime: $scenario', (tester) async {
      final client = Client('invite-clock', database: WindowDatabase());
      final ProtocolVoip voip = scenario == 'slow_peer'
          ? _DelayedVoip()
          : ProtocolVoip();
      voip.timeouts = CallTimeouts(
        callInviteLifetime: const Duration(seconds: 3),
      );
      final session = Session(
        CallOptions(
          callId: 'clock',
          type: CallType.kVoice,
          dir: CallDirection.kIncoming,
          localPartyId: 'local',
          voip: voip,
          room: Room(client: client, id: '!clock:fixture'),
          iceServers: [],
        ),
      );
      final peer = _Peer();
      final lifetime = scenario == 'already_expired'
          ? 0
          : scenario == 'local_cap'
          ? 120000
          : 1500;
      final initializing = session.initWithInvite(
        CallType.kVoice,
        rtc.RTCSessionDescription('offer', 'offer'),
        null,
        lifetime,
        false,
      );
      try {
        await tester.pump();
        if (scenario == 'slow_peer') {
          await tester.pump(const Duration(milliseconds: 1500));
          expect(
            session.callHasEnded,
            isTrue,
            reason: 'RTC setup cannot extend an incoming invite',
          );
          (voip as _DelayedVoip).delegate.ready.complete(peer);
          await initializing;
          expect(peer.disposals, 1);
        } else {
          await initializing;
          if (scenario == 'already_expired') {
            expect(session.callHasEnded, isTrue);
            expect(session.pc, isNull);
          } else {
            final expires = scenario == 'local_cap' ? 3000 : 1500;
            await tester.pump(Duration(milliseconds: expires - 1));
            expect(session.state, CallState.kRinging);
            await tester.pump(const Duration(milliseconds: 1));
            expect(session.callHasEnded, isTrue);
          }
        }
        expect(voip.delegate.mediaDevices.requested.isCompleted, isFalse);
        expect(session.hangupReason, CallErrorCode.inviteTimeout);
      } finally {
        if (voip is _DelayedVoip && !voip.delegate.ready.isCompleted) {
          voip.delegate.ready.complete(peer);
          await initializing;
        }
        await session.hangup(reason: CallErrorCode.userHangup);
        await client.dispose();
      }
    });
  }
}
