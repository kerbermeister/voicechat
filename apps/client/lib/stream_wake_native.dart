import 'package:flutter/services.dart';

class StreamWakeLock {
  bool _held = false;
  static const _channel = MethodChannel('voicechat/stream');
  Future<void> set(bool enabled) async {
    if (_held == enabled) return;
    _held = enabled;
    try {
      await _channel.invokeMethod<void>('keepAwake', enabled);
    } on PlatformException {
      _held = false;
      // Screen-awake support must never delay releasing camera/microphone.
    } on MissingPluginException {
      _held = false;
      /* Desktop support is a later platform stage. */
    }
  }
}
