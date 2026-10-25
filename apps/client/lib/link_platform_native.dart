import 'package:flutter/services.dart';
import 'transport.dart';
import 'user_action_error.dart';

Future<void> shareLink(Uri url) async {
  secureEndpoint(url.removeFragment().toString());
  try {
    await const MethodChannel(
      'voicechat/links',
    ).invokeMethod<void>('share', url.toString());
  } on PlatformException {
    throw UserActionError(
      'Не удалось открыть меню «Поделиться». Нажмите на ссылку, чтобы скопировать её в мессенджер.',
    );
  }
}

Future<void> openLink(Uri url) async {
  if (!['http', 'https'].contains(url.scheme) ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty) {
    throw const FormatException('Invalid link');
  }
  await const MethodChannel(
    'voicechat/links',
  ).invokeMethod<void>('open', url.toString());
}
