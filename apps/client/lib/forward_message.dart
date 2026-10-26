import 'dart:convert';
import 'package:matrix/matrix.dart';
import 'temporary_message.dart';
import 'user_action_error.dart';

const forwardedAuthorKey = 'dev.voicechat.forwarded_author';

String? forwardedAuthor(Event event) {
  final author = event.content[forwardedAuthorKey];
  return author is String && author.isNotEmpty && author.length <= 1024
      ? author
      : null;
}

bool canForwardMessage(Event event) =>
    !event.redacted &&
    !messageExpired(event) &&
    event.type == EventTypes.Message &&
    const {
      MessageTypes.Text,
      MessageTypes.Notice,
      MessageTypes.Emote,
      MessageTypes.Image,
      MessageTypes.Audio,
      MessageTypes.Video,
      MessageTypes.File,
      'dev.voicechat.file',
      'dev.voicechat.album',
      'dev.voicechat.call',
      'dev.voicechat.call_summary',
    }.contains(event.messageType);

/// Copy content, never room/event references, reply fallbacks or call signalling.
Map<String, dynamic> forwardMessageContent(Event event) {
  if (!canForwardMessage(event)) {
    throw UserActionError('Это сообщение больше нельзя переслать.');
  }
  final source = event.content;
  final content = <String, dynamic>{
    for (final key in [
      'msgtype',
      'body',
      'file',
      'url',
      'info',
      'mime',
      'size',
      'parts',
      'caption',
      'images',
      'video_note',
      'duration',
      'duration_ms',
      'video',
      'dev.voicechat.caption',
      'dev.voicechat.waveform',
    ])
      if (source.containsKey(key)) key: source[key],
    forwardedAuthorKey:
        forwardedAuthor(event) ??
        event.senderFromMemoryOrFallback.displayName ??
        event.senderId,
  };
  if (event.messageType == MessageTypes.Text ||
      event.messageType == MessageTypes.Notice ||
      event.messageType == MessageTypes.Emote) {
    content['body'] = event.calcUnlocalizedBody(hideReply: true);
  }
  // A forwarded call card is a message, not an invitation to the old session.
  if (event.messageType == 'dev.voicechat.call') {
    content['msgtype'] = 'dev.voicechat.call_summary';
  }
  if (messageExpiry(event) != null) {
    // This is a new message: preserve the validated retention duration, not a
    // shortened value that the server's TTL policy would reject.
    content['dev.voicechat.ttl_seconds'] =
        event.content['dev.voicechat.ttl_seconds'] ??
        event.originalSource?.content['dev.voicechat.ttl_seconds'];
  }
  return Map<String, dynamic>.from(jsonDecode(jsonEncode(content)) as Map);
}
