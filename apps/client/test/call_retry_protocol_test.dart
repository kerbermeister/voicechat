// Real Matrix CallSession termination, synthetic transport and no accounts.
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/voip/models/call_options.dart';
// ignore: implementation_imports
import 'package:matrix/src/voip/models/voip_id.dart';
import 'chat_actions_test.dart' show OutboxDatabase;
import 'direct_call_protocol_test.dart'
    show Delegate, Peer, ProtocolVoip, Session;

class _RetryDatabase extends OutboxDatabase {
  @override
  Future<void> close() async {}
}

class _RetryDelegate extends Delegate {
  final stopping = Completer<void>();
  @override
  Future<void> stopRingtone() => stopping.future;
}

class _RetryVoip extends ProtocolVoip {
  final _delegate = _RetryDelegate();
  @override
  _RetryDelegate get delegate => _delegate;
}

class _CleanupPeer extends Peer {
  bool disposed = false;
  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  for (final replacement in ['none', 'same_room', 'other_room']) {
    test(
      'Old missed-call cleanup survives replacement=$replacement while stopping ringtone',
      () async {
        final client = Client('retry-protocol', database: _RetryDatabase());
        final voip = _RetryVoip();
        final room = Room(client: client, id: '!old:fixture');
        final oldId = VoipId(roomId: room.id, callId: 'old');
        final old = Session(
          CallOptions(
            callId: oldId.callId,
            type: CallType.kVoice,
            dir: CallDirection.kIncoming,
            localPartyId: 'local',
            voip: voip,
            room: room,
            iceServers: [],
          ),
        );
        final peer = _CleanupPeer();
        old.pc = peer;
        voip.calls[oldId] = old;
        voip.currentCID = oldId;
        voip.incomingCallRoomId[room.id] = old.callId;
        old.setCallState(CallState.kRinging);
        try {
          final ending = old.hangup(reason: CallErrorCode.inviteTimeout);
          expect(old.state, CallState.kEnding);
          VoipId? newId;
          if (replacement != 'none') {
            newId = VoipId(
              roomId: replacement == 'same_room' ? room.id : '!new:fixture',
              callId: 'new',
            );
            voip.currentCID = newId;
            voip.incomingCallRoomId[newId.roomId] = newId.callId;
          }
          voip.delegate.stopping.complete();
          await ending;
          // ignore: avoid_print
          print(
            'CALL_RETRY_TERMINATION ${jsonEncode({'replacement': replacement, 'old_session_retained': voip.calls.containsKey(oldId), 'old_peer_disposed': peer.disposed, 'new_owner_preserved': voip.currentCID == newId})}',
          );
          expect(old.state, CallState.kEnded);
          expect(
            voip.currentCID,
            newId,
            reason: 'Old cleanup must preserve the new owner',
          );
          expect(
            voip.calls.containsKey(oldId),
            isFalse,
            reason:
                'Ended sessions must leave the routing map even after replacement',
          );
          expect(voip.incomingCallRoomId.values, isNot(contains(old.callId)));
          if (newId != null) {
            expect(voip.incomingCallRoomId[newId.roomId], newId.callId);
          }
          expect(
            peer.disposed,
            isTrue,
            reason:
                'Old PC/capture cleanup must not be skipped by a new currentCID',
          );
        } finally {
          if (!voip.delegate.stopping.isCompleted) {
            voip.delegate.stopping.complete();
          }
          await old.cleanUp();
          await client.dispose();
        }
      },
    );
  }
}
