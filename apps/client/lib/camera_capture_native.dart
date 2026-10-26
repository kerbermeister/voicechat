import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'call_quality.dart';

Future<void> replaceCameraTrack(
  rtc.RTCRtpSender sender,
  rtc.MediaStreamTrack? track,
) => sender.replaceTrack(track);

Future<rtc.MediaStream> captureCamera(String facing, VideoQuality quality) =>
    rtc.navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {
        'facingMode': facing,
        'width': quality.width,
        'height': quality.height,
        'frameRate': quality.fps,
      },
    });
