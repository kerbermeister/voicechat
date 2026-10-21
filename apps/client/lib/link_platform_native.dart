import 'package:flutter/services.dart';

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
