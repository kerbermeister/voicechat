import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/call_event.dart';
import 'chat_actions_test.dart' show OutboxDatabase;

void main() {
  final room = Room(
    id: '!call:local',
    client: Client('call-event-test', database: OutboxDatabase()),
  );
  Event invite(Object? offer) => Event.fromJson({
    'type': EventTypes.CallInvite,
    'event_id': r'$invite',
    'sender': '@caller:local',
    'content': {'offer': offer},
  }, room);
  test(
    'Native Matrix invitations distinguish video without displaying SDP',
    () {
      expect(
        callEventLabel(invite({'sdp': 'v=0\r\nm=audio 9 RTP/SAVPF 111\r\n'})),
        'Голосовой звонок',
      );
      expect(
        callEventLabel(invite({'sdp': 'v=0\r\nm=video 9 RTP/SAVPF 96\r\n'})),
        'Видеозвонок',
      );
      expect(callEventLabel(invite({'sdp': {}})), 'Голосовой звонок');
      expect(callEventLabel(invite(null)), 'Голосовой звонок');
    },
  );
}
