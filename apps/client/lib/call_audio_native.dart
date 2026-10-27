import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

Future<void> setCallTrackVolume(rtc.MediaStreamTrack track, double level) =>
    rtc.Helper.setVolume(level, track);
void forgetCallTrackVolume(String id) {}
