import 'dart:js_interop';

@JS('VoiceChatAudio.prepare')
external void prepareBrowserAudio();
@JS('VoiceChatAudio.play')
external JSPromise<JSBoolean> _play(
  JSString channel,
  JSString name,
  JSBoolean loop,
);
@JS('VoiceChatAudio.stop')
external void _stop(JSString channel);
@JS('VoiceChatAudio.resume')
external JSPromise<JSBoolean> _resume();
@JS('VoiceChatAudio.close')
external void closeBrowserAudio();
Future<bool> playBrowserSound(String channel, String name, bool loop) async =>
    (await _play(channel.toJS, name.toJS, loop.toJS).toDart).toDart;
void stopBrowserSound(String channel) => _stop(channel.toJS);
Future<bool> resumeBrowserAudio() async => (await _resume().toDart).toDart;
