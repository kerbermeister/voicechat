import 'package:web/web.dart' as web;
import 'device_description.dart';

Future<String> currentDeviceName() async =>
    'VoiceChat · ${browserDeviceDescription(web.window.navigator.userAgent, touchPoints: web.window.navigator.maxTouchPoints)}';
