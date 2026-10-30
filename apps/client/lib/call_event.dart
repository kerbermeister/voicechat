import 'package:matrix/matrix.dart';

bool isVideoCallEvent(Event event) {
  if (event.content['video'] == true) return true;
  final offer = event.content['offer'];
  return event.type == EventTypes.CallInvite &&
      offer is Map &&
      offer['sdp'] is String &&
      RegExp(r'^m=video ', multiLine: true).hasMatch(offer['sdp'] as String);
}

String callEventLabel(Event event) => event.type == EventTypes.CallInvite
    ? isVideoCallEvent(event)
          ? 'Видеозвонок'
          : 'Голосовой звонок'
    : switch (event.type) {
        EventTypes.CallHangup => 'Звонок завершён',
        'm.call.reject' => 'Звонок отклонён',
        'm.call.answer' => 'Ответ на звонок',
        _ =>
          event.content['body'] is String && event.text.isNotEmpty
              ? event.text
              : isVideoCallEvent(event)
              ? 'Видеозвонок'
              : 'Голосовой звонок',
      };

/// End/decline events can be sent by the callee; use the invitation, not the last sender.
String? callInitiator(Event event, {Iterable<Event> history = const []}) {
  if (event.content.containsKey('dev.voicechat.forwarded_author')) return null;
  bool invite(Event item) =>
      item.type == EventTypes.CallInvite ||
      item.content['msgtype'] == 'dev.voicechat.call' &&
          item.content['action'] == 'invite';
  if (invite(event)) return event.senderId;
  final session = event.content['session'] ?? event.content['call_id'];
  if (session is String) {
    for (final candidate in history) {
      if (candidate.room.id == event.room.id &&
          invite(candidate) &&
          (candidate.content['session'] ?? candidate.content['call_id']) ==
              session) {
        return candidate.senderId;
      }
    }
  }
  final recorded = event.content['dev.voicechat.call_initiator'];
  if (recorded is String &&
      recorded.startsWith('@') &&
      recorded.contains(':')) {
    return recorded;
  }
  // Our direct-call summary is written only by the outgoing device.
  if (event.content['msgtype'] == 'dev.voicechat.call_summary') {
    return event.senderId;
  }
  return null;
}

String? callDirectionLabel(Event event, {Iterable<Event> history = const []}) {
  final initiator = callInitiator(event, history: history);
  if (initiator == null || event.room.client.userID == null) return null;
  return initiator == event.room.client.userID
      ? 'Исходящий звонок'
      : 'Входящий звонок';
}
