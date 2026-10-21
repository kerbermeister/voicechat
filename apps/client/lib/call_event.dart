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
    : event.body;
