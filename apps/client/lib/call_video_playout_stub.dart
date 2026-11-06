import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
// ignore: implementation_imports
import 'package:flutter_webrtc/src/native/rtc_rtp_receiver_impl.dart';

void tuneCallVideoPlayout(rtc.RTCRtpReceiver? receiver) {
  unawaited(tuneMacOSCallVideoPlayout(receiver));
}

void tuneCallAudioPlayout(rtc.RTCRtpReceiver? receiver) {
  unawaited(tuneMacOSCallAudioPlayout(receiver));
}

Future<bool> tuneMacOSCallVideoPlayout(rtc.RTCRtpReceiver? receiver) {
  return _tuneMacOSCallPlayout(receiver, 'video', 'tuneVideoPlayout');
}

Future<bool> tuneMacOSCallAudioPlayout(rtc.RTCRtpReceiver? receiver) {
  return _tuneMacOSCallPlayout(receiver, 'audio', 'tuneAudioPlayout');
}

Future<bool> _tuneMacOSCallPlayout(
  rtc.RTCRtpReceiver? receiver,
  String kind,
  String method,
) async {
  if (defaultTargetPlatform != TargetPlatform.macOS ||
      receiver is! RTCRtpReceiverNative ||
      receiver.track.kind != kind) {
    return false;
  }
  try {
    return await const MethodChannel(
          'voicechat/calls',
        ).invokeMethod<bool>(method, {
          'peerConnectionId': receiver.peerConnectionId,
          'receiverId': receiver.receiverId,
        }) ??
        false;
  } on PlatformException catch (error) {
    debugPrint('Could not tune macOS $kind playout: ${error.code}');
    return false;
  } on MissingPluginException {
    return false;
  }
}
