import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:web/web.dart' as web;
// Explicit web implementation keeps platform-specific overrides analyzable on a native host.
// ignore: implementation_imports
import 'package:flutter_webrtc/src/web/rtc_video_renderer_impl.dart'
    as renderer;

renderer.RTCVideoRenderer createCallRenderer() => _CallRenderer();

// The SDK splits a combined remote stream into independent audio/video players.
// Keep both tracks on the video player so the browser can synchronize playout.
// Audio-only calls keep the SDK's audio player.
class _CallRenderer extends renderer.RTCVideoRenderer {
  bool _local = false;

  void _bindPlayback() {
    final video = findHtmlView();
    final stream = srcObject;
    final combined =
        video != null && stream != null && stream.getVideoTracks().isNotEmpty;
    super.muted = _local || combined;
    if (video != null && stream is MediaStreamWeb) {
      video.srcObject = stream.jsStream;
      video.muted = _local || !combined;
    }
  }

  @override
  set muted(bool value) {
    _local = value;
    _bindPlayback();
  }

  @override
  Future<void> setSrcObject({rtc.MediaStream? stream, String? trackId}) async {
    if (stream != null) _local = stream.ownerTag == 'local';
    await super.setSrcObject(stream: stream, trackId: trackId);
    _bindPlayback();
  }

  @override
  web.HTMLVideoElement createElement() {
    final video = super.createElement();
    final stream = srcObject;
    if (stream is MediaStreamWeb) video.srcObject = stream.jsStream;
    video.muted = _local || stream == null || stream.getVideoTracks().isEmpty;
    super.muted = true;
    return video;
  }
}
