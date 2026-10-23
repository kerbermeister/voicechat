import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// Исходный захват живёт отдельно от публикаций сменяемых SFU-поколений.
class ScreenCapture {
  static bool get supported => kIsWeb
      ? !lk.lkPlatformIsWebMobile()
      : defaultTargetPlatform == TargetPlatform.android;
  final lk.LocalVideoTrack source;
  bool _closed = false;
  static const _native = MethodChannel('voicechat/screen');
  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  ScreenCapture(this.source);

  static Future<ScreenCapture> start() async {
    if (!supported) throw UnsupportedError('Screen capture unavailable');
    if (_android) {
      // Android 14: consent → foreground service → SDK getMediaProjection.
      if (!await rtc.Helper.requestCapturePermission()) {
        throw StateError('Screen permission denied');
      }
      await _native.invokeMethod<void>('start');
    }
    try {
      final track = await lk.LocalVideoTrack.createScreenShareTrack(
        const lk.ScreenShareCaptureOptions(
          captureScreenAudio: false,
          maxFrameRate: 15,
        ),
      );
      if (track.mediaStream.getAudioTracks().isNotEmpty) {
        await track.dispose();
        throw StateError('Unexpected screen audio');
      }
      final capture = ScreenCapture(track);
      if (_android) {
        _native.setMethodCallHandler((call) async {
          if (call.method == 'stop') {
            track.mediaStreamTrack.onEnded?.call();
            await capture.close();
          }
        });
      }
      return capture;
    } catch (_) {
      if (_android) await _native.invokeMethod<void>('stop');
      rethrow;
    }
  }

  Future<lk.LocalVideoTrack> publication() async {
    if (_closed) throw StateError('Capture closed');
    if (!kIsWeb) {
      final ended = source.mediaStreamTrack.onEnded;
      final track = _ScreenPublication(source);
      source.mediaStreamTrack.onEnded = ended;
      return track;
    }
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
    try {
      await source.dispose();
    } finally {
      if (_android) {
        _native.setMethodCallHandler(null);
        await _native.invokeMethod<void>('stop');
      }
    }
  }
}

// shortcut: native stream.clone в flutter_webrtc 1.6.2 повторно использует track.
// Публикация заимствует его; единственный владелец projection — ScreenCapture.
// Заменить поддерживаемым SDK factory с внешним владением capture.
class _ScreenPublication extends lk.LocalVideoTrack {
  _ScreenPublication(lk.LocalVideoTrack source)
    // ignore: invalid_use_of_internal_member
    : super(
        lk.TrackSource.screenShareVideo,
        source.mediaStream,
        source.mediaStreamTrack,
        source.currentOptions,
      );
  @override
  // Root capture выполняет stop; super.stop уничтожил бы чужой native track.
  // ignore: must_call_super
  Future<bool> stop() async => false;
}
