import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
// ignore: implementation_imports
import 'package:matrix/src/voip/models/call_options.dart';
import 'package:voicechat_probe/call_push_rules.dart';
import 'chat_actions_test.dart' show OutboxDatabase;

class RuleDatabase extends OutboxDatabase {
  @override
  Future<void> close() async {}
}

class EnvelopeEncryption extends Fake implements Encryption {
  @override
  Future<void> dispose() async {}
  @override
  Future<Map<String, dynamic>> encryptGroupMessagePayload(
    String roomId,
    Map<String, dynamic> payload, {
    String type = EventTypes.Message,
  }) async => {'ciphertext': 'synthetic', 'algorithm': 'm.megolm.v1.aes-sha2'};
}

class EnvelopeVoip extends Fake implements VoIP {}

class EnvelopeClient extends Client {
  EnvelopeClient() : super('envelope', database: RuleDatabase());
  @override
  String get userID => '@owner:example';
  @override
  final encryption = EnvelopeEncryption();
  @override
  bool get encryptionEnabled => true;
  final sent = <Map<String, dynamic>>[];
  @override
  Future<String> sendMessage(
    String roomId,
    String eventType,
    String txnId,
    Map<String, dynamic> content,
  ) async {
    expect(eventType, EventTypes.Encrypted);
    sent.add(content);
    return '\$event${sent.length}';
  }
}

class EncryptedRoom extends Room {
  EncryptedRoom(Client client) : super(id: '!room:example', client: client);
  @override
  bool get encrypted => true;
}

void main() {
  test(
    'Only hidden call signalling and summaries carry a silent encryption hint',
    () async {
      final client = EnvelopeClient();
      final room = EncryptedRoom(client);
      final call = CallSession(
        CallOptions(
          callId: 'private',
          type: CallType.kVoice,
          dir: CallDirection.kOutgoing,
          localPartyId: 'device',
          voip: EnvelopeVoip(),
          room: room,
          iceServers: [],
        ),
      );
      await call.sendCallReject(room, 'private', 'device');
      expect(client.sent.last, {
        'ciphertext': 'synthetic',
        'algorithm': 'm.megolm.v1.aes-sha2',
        'dev.voicechat.silent': true,
      });
      await call.sendInviteToCall(room, 'private', 60000, 'device', 'private');
      expect(client.sent.last.containsKey('dev.voicechat.silent'), false);
      for (final type in [
        'm.call.candidates',
        'm.call.answer',
        'm.call.hangup',
        'm.call.sdp_stream_metadata_changed',
      ]) {
        await room.sendEvent(
          {'call_id': 'private', 'sdp': 'private'},
          type: type,
          displayPendingEvent: false,
        );
        expect(client.sent.last, {
          'ciphertext': 'synthetic',
          'algorithm': 'm.megolm.v1.aes-sha2',
          'dev.voicechat.silent': true,
        });
      }
      for (final content in [
        {'msgtype': 'dev.voicechat.call_summary', 'session': 'private'},
        {
          'msgtype': 'dev.voicechat.call',
          'action': 'end',
          'session': 'private',
        },
      ]) {
        await room.sendEvent(content, displayPendingEvent: false);
        expect(client.sent.last['dev.voicechat.silent'], true);
      }
      for (final type in [EventTypes.CallInvite, EventTypes.Message]) {
        await room.sendEvent(
          {'body': 'private', 'msgtype': 'm.text'},
          type: type,
          displayPendingEvent: false,
        );
        expect(client.sent.last.containsKey('dev.voicechat.silent'), false);
        expect(client.sent.last.containsKey('body'), false);
      }
      await room.sendEvent({
        'msgtype': 'dev.voicechat.call',
        'action': 'invite',
      }, displayPendingEvent: false);
      expect(client.sent.last.containsKey('dev.voicechat.silent'), false);
      await client.dispose();
    },
  );
  test(
    'Silent ciphertext push override matches escaped field and does not mute rooms',
    () async {
      final client = Client(
        'push-rule',
        database: RuleDatabase(),
        httpClient: MockClient((request) async {
          expect(request.method, 'PUT');
          expect(
            request.url.path,
            endsWith('/pushrules/global/override/dev.voicechat.silent'),
          );
          expect(jsonDecode(request.body), {
            'actions': [],
            'conditions': [
              {
                'kind': 'event_property_is',
                'key': r'content.dev\.voicechat\.silent',
                'value': true,
              },
            ],
          });
          return http.Response('{}', 200);
        }),
      );
      client.homeserver = Uri.parse('https://matrix.example');
      client.accessToken = 'fixture';
      await installCallPushRule(client);
      await client.dispose();
    },
  );
}
