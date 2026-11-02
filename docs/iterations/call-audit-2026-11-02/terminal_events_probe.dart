// Terminal invariant against all permutations of four late callbacks.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:matrix/matrix.dart';
import 'package:matrix/src/voip/models/call_options.dart';

import '../../../apps/client/test/direct_call_protocol_test.dart' as fixture;
import '../../../apps/client/test/chat_actions_test.dart' show OutboxDatabase;

Iterable<List<int>> permutations(List<int> items) sync* {
  if (items.isEmpty) {
    yield [];
    return;
  }
  for (final item in items) {
    for (final tail in permutations(items.where((x) => x != item).toList())) {
      yield [item, ...tail];
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('24 late event orderings cannot resurrect a hung-up call', (
    tester,
  ) async {
    final client = Client('qa-terminal', database: OutboxDatabase());
    for (final order in permutations([0, 1, 2, 3])) {
      final voip = fixture.ProtocolVoip();
      final call = fixture.Session(
        CallOptions(
          callId: 'qa',
          type: CallType.kVoice,
          dir: CallDirection.kIncoming,
          localPartyId: 'a',
          voip: voip,
          room: Room(client: client, id: '!qa:local'),
          iceServers: [],
        ),
      );
      await call.initWithInvite(
        CallType.kVoice,
        rtc.RTCSessionDescription('offer', 'offer'),
        null,
        60000,
        false,
      );
      await call.hangup(reason: CallErrorCode.userHangup);
      final events = <void Function()>[
        () => call.setCallState(CallState.kConnecting),
        () => voip.delegate.peer.onIceConnectionState?.call(
          rtc.RTCIceConnectionState.RTCIceConnectionStateCompleted,
        ),
        () => voip.delegate.peer.onConnectionState?.call(
          rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected,
        ),
        () => voip.delegate.peer.onConnectionState?.call(
          rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed,
        ),
      ];
      for (final i in order) {
        events[i]();
        expect(call.state, CallState.kEnded, reason: '$order after $i');
      }
      await tester.pump(const Duration(seconds: 31));
      expect(call.hangups, 1);
      expect(call.answers, 0);
      await call.cleanUp();
    }
    await client.dispose();
  });
}
