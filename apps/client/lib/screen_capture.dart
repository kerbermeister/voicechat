import 'package:livekit_client/livekit_client.dart' as lk;

/// Исходный захват живёт отдельно от публикаций сменяемых SFU-поколений.
class ScreenCapture {
  final lk.LocalVideoTrack source;
  bool _closed = false;
  ScreenCapture(this.source);

  static Future<ScreenCapture> start() async {
    final track = await lk.LocalVideoTrack.createScreenShareTrack(
      const lk.ScreenShareCaptureOptions(captureScreenAudio: false),
    );
    if (track.mediaStream.getAudioTracks().isNotEmpty) {
      await track.dispose();
      throw StateError('Unexpected screen audio');
    }
    return ScreenCapture(track);
  }

  Future<lk.LocalVideoTrack> publication() async {
    if (_closed) throw StateError('Capture closed');
    final stream = await source.mediaStream.clone();
    if (_closed) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
      throw StateError('Capture closed during clone');
    }
    // shortcut: SDK 2.13.1 не имеет public factory из готового screen stream.
    // Заменить при появлении поддерживаемого factory; web clone проверен SS-01.
    // ignore: invalid_use_of_internal_member
    return lk.LocalVideoTrack(
      lk.TrackSource.screenShareVideo,
      stream,
      stream.getVideoTracks().single,
      source.currentOptions,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await source.dispose();
  }
}
