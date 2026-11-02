import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/voip/models/call_options.dart';
import 'call_push_rules_test.dart'
    show EnvelopeClient, EncryptedRoom, EnvelopeVoip;
import 'direct_call_protocol_test.dart' show Peer, ProtocolVoip, Session;

class _LimitedClient extends EnvelopeClient {
  final attempts =
      <({String type, String transaction, Map<String, dynamic> content})>[];
  final failures = <MatrixException>[];
  @override
  Future<String> sendMessage(
    String roomId,
    String eventType,
    String txnId,
    Map<String, dynamic> content,
  ) async {
    attempts.add((type: eventType, transaction: txnId, content: content));
    if (failures.isNotEmpty) throw failures.removeAt(0);
    return 'synthetic-event';
  }
}

MatrixException limited({int? milliseconds = 1000, String? header}) =>
    MatrixException(
      http.Response(
        jsonEncode({
          'errcode': 'M_LIMIT_EXCEEDED',
          if (milliseconds != null) 'retry_after_ms': milliseconds,
        }),
        429,
        headers: {if (header != null) 'retry-after': header},
      ),
    );

void main() {
  testWidgets('Local offer failure sends terminal signalling to the peer', (
    tester,
  ) async {
    final client = _LimitedClient();
    final room = EncryptedRoom(client);
    final voip = ProtocolVoip();
    final call = Session(
      CallOptions(
        callId: 'failed-offer',
        type: CallType.kVoice,
        dir: CallDirection.kOutgoing,
        localPartyId: 'device',
        voip: voip,
        room: room,
        iceServers: [],
      ),
    )..pc = Peer();
    call.setCallState(CallState.kCreateOffer);
    // The fixture peer does not implement createOffer: exercise the real error path.
    final negotiating = call.onNegotiationNeeded();
    await tester.pump(const Duration(milliseconds: 100));
    await negotiating;
    expect(call.state, CallState.kEnded);
    expect(call.hangups, 1);
    await tester.runAsync(client.dispose);
  });
  for (final scenario in [
    'body',
    'header',
    'cancel',
    'terminal',
    'exhausted',
    'long',
    'forbidden',
    'invalid_header',
    'no_hint',
    'zero_delay',
    'wait_budget',
  ]) {
    testWidgets('Call signalling rate limit: $scenario', (tester) async {
      final client = _LimitedClient();
      final room = EncryptedRoom(client);
      final call = CallSession(
        CallOptions(
          callId: 'own-call',
          type: CallType.kVoice,
          dir: CallDirection.kOutgoing,
          localPartyId: 'device',
          voip: EnvelopeVoip(),
          room: room,
          iceServers: [],
        ),
      );
      final firstFailure = scenario == 'forbidden'
          ? MatrixException.fromJson({'errcode': 'M_FORBIDDEN'})
          : limited(
              milliseconds: switch (scenario) {
                'long' => 60000,
                'no_hint' => null,
                'zero_delay' => 0,
                'wait_budget' => 6000,
                _ => 1000,
              },
              header: switch (scenario) {
                'header' => '2',
                'invalid_header' => 'unrecognized',
                _ => null,
              },
            );
      client.failures.add(firstFailure);
      if (scenario == 'exhausted') {
        client.failures.addAll(List.generate(3, (_) => limited()));
      }
      if (scenario == 'wait_budget') {
        client.failures.addAll(
          List.generate(2, (_) => limited(milliseconds: 6000)),
        );
      }
      if (scenario == 'terminal') call.setCallState(CallState.kEnded);
      var finished = false;
      final operation =
          (scenario == 'terminal'
                  ? call.sendHangupCall(
                      room,
                      'own-call',
                      'device',
                      'user_hangup',
                    )
                  : call.sendInviteToCall(
                      room,
                      'own-call',
                      45000,
                      'device',
                      'synthetic-sdp',
                    ))
              .then<Object?>(
                (result) {
                  finished = true;
                  return result;
                },
                onError: (Object error) {
                  finished = true;
                  return error;
                },
              );
      await tester.pump();
      expect(client.attempts, hasLength(1));
      if (['long', 'forbidden', 'invalid_header'].contains(scenario)) {
        expect(await operation, same(firstFailure));
      } else {
        expect(finished, isFalse);
        if (scenario == 'cancel') call.setCallState(CallState.kEnded);
        final delay = switch (scenario) {
          'header' => 2000,
          'zero_delay' => 100,
          'wait_budget' => 6000,
          _ => 1000,
        };
        await tester.pump(Duration(milliseconds: delay - 1));
        expect(client.attempts, hasLength(1));
        await tester.pump(const Duration(milliseconds: 1));
        if (scenario == 'exhausted') {
          await tester.pump(const Duration(seconds: 1));
          await tester.pump(const Duration(seconds: 1));
          expect(await operation, isA<MatrixException>());
          expect(client.attempts, hasLength(4));
        } else if (scenario == 'wait_budget') {
          await tester.pump(const Duration(seconds: 6));
          expect(await operation, isA<MatrixException>());
          expect(client.attempts, hasLength(3));
        } else {
          expect(
            await operation,
            scenario == 'cancel' ? isNull : 'synthetic-event',
          );
          expect(client.attempts, hasLength(scenario == 'cancel' ? 1 : 2));
        }
      }
      expect(client.attempts.map((a) => a.transaction).toSet(), hasLength(1));
      for (final attempt in client.attempts) {
        expect(attempt.type, EventTypes.Encrypted);
        expect(attempt.content, same(client.attempts.first.content));
        expect(attempt.content.containsKey('offer'), isFalse);
        expect(attempt.content.containsKey('sdp'), isFalse);
      }
      await tester.runAsync(client.dispose);
    });
  }
}
