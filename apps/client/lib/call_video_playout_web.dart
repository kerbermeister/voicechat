import 'dart:js_interop';
import 'dart:js_interop_unsafe';

// ignore: implementation_imports
import 'package:dart_webrtc/src/rtc_rtp_receiver_impl.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:web/web.dart' as web;

void tuneCallAudioPlayout(rtc.RTCRtpReceiver? receiver) {}

void tuneCallVideoPlayout(rtc.RTCRtpReceiver? receiver) {
  if (receiver is RTCRtpReceiverWeb) {
    applyCallVideoPlayoutTarget(receiver.jsRtpReceiver);
  }
}

void applyCallVideoPlayoutTarget(web.RTCRtpReceiver receiver) {
  if (receiver.track.kind != 'video' ||
      !receiver.hasProperty('jitterBufferTarget'.toJS).toDart) {
    return;
  }
  // Keep decoded camera frames closer to the audio played by Web Audio.
  // This is a browser target and the receiver can adapt to network conditions.
  receiver.jitterBufferTarget = 130;
}
