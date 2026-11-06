import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
// ignore: implementation_imports
import 'package:flutter_webrtc/src/native/rtc_rtp_receiver_impl.dart';

void tuneCallVideoPlayout(rtc.RTCRtpReceiver? receiver) {
  unawaited(tuneMacOSCallVideoPlayout(receiver));
}

Future<bool> tuneMacOSCallVideoPlayout(rtc.RTCRtpReceiver? receiver) async {
  if (defaultTargetPlatform != TargetPlatform.macOS ||
      receiver is! RTCRtpReceiverNative ||
      receiver.track.kind != 'video') {
    return false;
  }
  try {
    return await const MethodChannel(
          'voicechat/calls',
        ).invokeMethod<bool>('tuneVideoPlayout', {
          'peerConnectionId': receiver.peerConnectionId,
          'receiverId': receiver.receiverId,
        }) ??
        false;
  } on PlatformException catch (error) {
    debugPrint('Could not tune macOS camera playout: ${error.code}');
    return false;
  } on MissingPluginException {
    return false;
  }
}
