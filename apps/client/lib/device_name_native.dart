import 'dart:io';
import 'package:flutter/services.dart';

Future<String> currentDeviceName() async {
  if (Platform.isAndroid) {
    try {
      final name = await const MethodChannel(
        'voicechat/device',
      ).invokeMethod<String>('description');
      if (name != null && name.isNotEmpty) return 'VoiceChat · $name';
    } on PlatformException {
      // Device naming is optional and must not prevent login.
    } on MissingPluginException {
      // Desktop/test hosts do not register the Android channel.
    }
  }
  return 'VoiceChat · ${Platform.isMacOS
      ? 'Mac · macOS'
      : Platform.isIOS
      ? 'iPhone / iPad · iOS'
      : Platform.operatingSystem}';
}
