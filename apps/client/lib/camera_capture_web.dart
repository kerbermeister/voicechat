import 'dart:js_interop';
import 'package:web/web.dart' as web;
// ignore: depend_on_referenced_packages
import 'package:dart_webrtc/dart_webrtc.dart' as rtc;
import 'camera_capture.dart' show cameraConstraints;
import 'call_quality.dart';
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:dart_webrtc/src/rtc_rtp_sender_impl.dart' show RTCRtpSenderWeb;

Future<void> replaceCameraTrack(
  rtc.RTCRtpSender sender,
  rtc.MediaStreamTrack? track,
) async {
  // dart_webrtc 1.8.2 drops this promise; failures must reach rollback handling.
  await (sender as RTCRtpSenderWeb).jsRtpSender
      .replaceTrack((track as rtc.MediaStreamTrackWeb?)?.jsTrack)
      .toDart;
}

Future<rtc.MediaStream> captureCamera(
  String facing,
  VideoQuality quality,
) async {
  // Preserve facingMode also with iPad/desktop-mode user agents.
  final stream = await web.window.navigator.mediaDevices
      .getUserMedia(
        cameraConstraints(facing, quality).jsify()
            as web.MediaStreamConstraints,
      )
      .toDart;
  return rtc.MediaStreamWeb(stream, 'local');
}
