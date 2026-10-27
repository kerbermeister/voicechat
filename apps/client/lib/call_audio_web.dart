import 'dart:js_interop';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

@JS('VoiceChatAudio.setCallVolume')
external JSPromise<JSAny?> _set(JSString id, JSNumber level);
@JS('VoiceChatAudio.forgetCallVolume')
external void _forget(JSString id);
Future<void> setCallTrackVolume(
  rtc.MediaStreamTrack track,
  double level,
) async {
  await _set(track.id!.toJS, level.toJS).toDart;
}

void forgetCallTrackVolume(String id) => _forget(id.toJS);
