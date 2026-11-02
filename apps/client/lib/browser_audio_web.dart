import 'dart:js_interop';
import 'dart:convert';
import 'package:flutter/services.dart';

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

@JS('VoiceChatAudio.outputDevices')
external JSPromise<JSString> _outputs();
@JS('VoiceChatAudio.selectOutput')
external JSPromise<JSAny?> _selectOutput(JSString id);
@JS('VoiceChatAudio.chooseSystemOutput')
external JSPromise<JSAny?> _chooseOutput();
Future<Map<String, dynamic>> browserAudioOutputs() async =>
    jsonDecode((await _outputs().toDart).toDart) as Map<String, dynamic>;
Future<void> selectBrowserAudioOutput(String id) async {
  try {
    await _selectOutput(id.toJS).toDart;
  } catch (_) {
    throw PlatformException(
      code: 'audio_route',
      message:
          'Браузер не переключил аудиовыход. Проверьте подключение устройства и разрешение на выбор динамика.',
    );
  }
}

Future<void> chooseBrowserAudioOutput() async {
  try {
    await _chooseOutput().toDart;
  } catch (_) {
    throw PlatformException(
      code: 'audio_route',
      message: 'Аудиовыход не выбран. Можно повторить выбор устройства.',
    );
  }
}
