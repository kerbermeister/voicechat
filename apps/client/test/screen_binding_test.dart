import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/direct_call.dart';
import 'package:voicechat_probe/screen_binding.dart';
import 'package:voicechat_probe/user_action_error.dart';

class SignalDatabase extends Fake implements mx.DatabaseApi {}

class SignalSession extends Fake implements mx.CallSession {
  @override
  String get remotePartyId => 'random-voip-party';
  @override
  String get remoteUserId => '@peer:x';
}

class SignalCall extends Fake implements DirectCall {
  @override
  final mx.Room chat;
  SignalCall(this.chat);
  @override
  mx.CallSession get call => SignalSession();
  @override
  String get session => 'session';
}

void main() {
  test(
    'Случайный party связан с encrypted sender, plaintext и повтор не подменяют его',
    () {
      final client = mx.Client('signal', database: SignalDatabase());
      final room = mx.Room(id: '!r:x', client: client);
      final parties = ScreenCallParties(), call = SignalCall(room);
      mx.Event event(String key, {bool encrypted = true}) => mx.Event.fromJson({
        'type': mx.EventTypes.CallAnswer,
        'sender': '@peer:x',
        'content': {
          'call_id': 'session',
          'party_id': 'random-voip-party',
          'invitee_device_id': 'WRONG',
        },
        if (encrypted)
          'original_source': {
            'type': mx.EventTypes.Encrypted,
            'event_id': r'$encrypted',
            'origin_server_ts': 1,
            'sender': '@peer:x',
            'content': {'sender_key': key},
          },
      }, room);
      parties.observe([event('a' * 43, encrypted: false)]);
      expect(parties.curve(call), isNull);
      parties.observe([event('b' * 43)]);
      expect(parties.curve(call), 'b' * 43);
      parties.observe([event('c' * 43)]);
      expect(parties.curve(call), 'b' * 43);
    },
  );
  test(
    'Выбрано доверенное устройство ответившей стороны, а не другое её устройство',
    () {
      expect(
        selectedScreenPeer('@peer:x', 'curve-answer', [
          (user: '@peer:x', device: 'OTHER', curve: 'curve-other'),
          (user: '@peer:x', device: 'ANSWER', curve: 'curve-answer'),
        ]),
        {'user_id': '@peer:x', 'device_id': 'ANSWER'},
      );
    },
  );
  test(
    'Чужой или отсутствующий sender key не становится экранным допуском',
    () {
      for (final party in <String?>[null, 'UNKNOWN', 'DEVICE']) {
        expect(
          () => selectedScreenPeer('@peer:x', party, [
            (user: '@other:x', device: 'DEVICE', curve: 'curve-device'),
          ]),
          throwsA(isA<UserActionError>()),
        );
      }
    },
  );
}
