import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/forward_message.dart';
import 'package:voicechat_probe/user_action_error.dart';
import 'conversation_list_test.dart' show ListClient;

void main() {
  final room = Room(id: '!source:local', client: ListClient());
  room.states[EventTypes.RoomMember] = {
    '@alice:local': StrippedStateEvent(
      type: EventTypes.RoomMember,
      stateKey: '@alice:local',
      senderId: '@alice:local',
      content: {'membership': 'join', 'displayname': 'Alice'},
    ),
  };
  Event event(Map<String, dynamic> content) => Event.fromJson({
    'type': EventTypes.Message,
    'event_id': r'$source',
    'sender': '@alice:local',
    'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
    'content': content,
  }, room);
  test(
    'Forward strips reply, HTML, source and call metadata; keeps original author on repeated forward',
    () {
      final source = event({
        'msgtype': MessageTypes.Text,
        'body': '> <@bob:local> private quote\n\nHello',
        'format': 'org.matrix.custom.html',
        'formatted_body': '<mx-reply>secret</mx-reply>Hello',
        'm.relates_to': {
          'm.in_reply_to': {'event_id': r'$secret'},
        },
        'session': 'secret-call',
        'room_id': room.id,
        forwardedAuthorKey: 'Original author',
      });
      final content = forwardMessageContent(source);
      expect(content, {
        'msgtype': MessageTypes.Text,
        'body': 'Hello',
        forwardedAuthorKey: 'Original author',
      });
      expect(source.content['session'], 'secret-call');
      expect(forwardMessageContent(event(content)), content);
    },
  );
  test(
    'Attachment manifests survive independently and forwarding cannot revive expired content',
    () {
      final source = event({
        'msgtype': 'dev.voicechat.file',
        'body': 'clip.mp4',
        'mime': 'video/mp4',
        'size': 4,
        'video_note': true,
        'duration': 1000,
        'parts': [
          {
            'file': {
              'key': {'k': 'encrypted-key'},
              'url': 'mxc://local/media',
            },
            'size': 4,
          },
        ],
      });
      final copy = forwardMessageContent(source);
      expect(copy['parts'], source.content['parts']);
      (copy['parts'] as List).clear();
      expect(source.content['parts'], hasLength(1));
      final temporary = event({
        'msgtype': MessageTypes.Text,
        'body': 'temporary',
        'dev.voicechat.ttl_seconds': 60,
      });
      expect(forwardMessageContent(temporary)['dev.voicechat.ttl_seconds'], 60);
      final expired = event({
        'msgtype': MessageTypes.Text,
        'body': 'gone',
        'dev.voicechat.ttl_seconds': 1,
      });
      expired.originServerTs = DateTime.now().subtract(
        const Duration(seconds: 5),
      );
      expect(
        () => forwardMessageContent(expired),
        throwsA(isA<UserActionError>()),
      );
    },
  );
  test('Forwarding a group call cannot trigger an invitation', () {
    final content = forwardMessageContent(
      event({
        'msgtype': 'dev.voicechat.call',
        'body': 'Звонок',
        'action': 'invite',
        'session': 'call',
      }),
    );
    expect(content['msgtype'], 'dev.voicechat.call_summary');
    expect(content.containsKey('action'), false);
    expect(content.containsKey('session'), false);
  });
}
