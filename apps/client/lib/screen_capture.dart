import 'dart:async';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'screen_capture_support.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

String screenCaptureNotice(Object error) {
  if (error is PlatformException &&
      {'screenPermissionDenied', 'screenNoFrames'}.contains(error.code)) {
    return error.code == 'screenPermissionDenied'
        ? 'macOS не разрешила запись экрана этой версии VoiceChat. В «Системные настройки → Конфиденциальность и безопасность → Запись экрана» выключите и снова включите VoiceChat, затем полностью закройте и откройте приложение. После обновления старая галочка может сохраняться.'
        : 'macOS не передала кадры экрана. Показ не начат. Проверьте разрешение на запись экрана для VoiceChat и полностью перезапустите приложение.';
  }
  if (error is UnsupportedError) {
    return 'Эта версия браузера или ОС не поддерживает захват экрана.';
  }
  final code = RegExp(
    r'\b(NotAllowedError|InvalidStateError|NotReadableError|NotFoundError|NotSupportedError|AbortError)\b',
  ).firstMatch(error.toString())?.group(1);
  return switch (code) {
    'NotAllowedError' =>
      'Доступ к экрану не разрешён. Повторите показ и подтвердите системный запрос.',
    'InvalidStateError' =>
      'Вернитесь в webapp и снова нажмите «Показать экран».',
    'NotReadableError' =>
      'Система не смогла начать захват. Остановите прежний показ и повторите попытку.',
    'NotFoundError' || 'NotSupportedError' =>
      'Эта версия браузера или ОС не предоставляет экран для показа.',
    'AbortError' => 'Системный выбор экрана прерван. Можно начать показ снова.',
    _ => 'Показ не начат. Проверьте разрешение на захват экрана.',
  };
}

/// Исходный захват живёт отдельно от публикаций сменяемых SFU-поколений.
class ScreenCapture {
  static bool get supported => kIsWeb
      ? browserScreenCaptureSupported
      : const {
          TargetPlatform.android,
          TargetPlatform.macOS,
          TargetPlatform.windows,
          TargetPlatform.linux,
        }.contains(defaultTargetPlatform);
  final lk.LocalVideoTrack source;
  bool _closed = false;
  static const _native = MethodChannel('voicechat/screen');
  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  ScreenCapture(this.source);

  static Future<ScreenCapture> start() async {
    if (!supported) throw UnsupportedError('Screen capture unavailable');
    final macOS = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    if (macOS && !await rtc.Helper.requestCapturePermission()) {
      throw PlatformException(code: 'screenPermissionDenied');
    }
    if (_android) {
      // Android 14: consent → foreground service → SDK getMediaProjection.
      if (!await rtc.Helper.requestCapturePermission()) {
        throw StateError('Screen permission denied');
      }
      await _native.invokeMethod<void>('start');
    }
    try {
      const options = lk.ScreenShareCaptureOptions(
        captureScreenAudio: false,
        maxFrameRate: 15,
      );
      final lk.LocalVideoTrack track;
      if (kIsWeb) {
        // shortcut: LiveKit 2.13 rejects every mobile browser before API detection.
        // Use the same track factory until its mobile restriction is removed.
        final stream = await rtc.navigator.mediaDevices.getDisplayMedia({
          'audio': false,
          'video': {'frameRate': 15},
        });
        if (stream.getVideoTracks().isEmpty) {
          for (final item in stream.getTracks()) {
            await item.stop();
          }
          await stream.dispose();
          throw StateError('Screen capture returned no video');
        }
        // ignore: invalid_use_of_internal_member
        track = lk.LocalVideoTrack(
          lk.TrackSource.screenShareVideo,
          stream,
          stream.getVideoTracks().single,
          options,
        );
      } else {
        track = await lk.LocalVideoTrack.createScreenShareTrack(options);
      }
      if (track.mediaStream.getAudioTracks().isNotEmpty) {
        await track.dispose();
        throw StateError('Unexpected screen audio');
      }
      if (macOS) {
        try {
          await _waitForFrames(track);
        } catch (_) {
          await track.dispose();
          rethrow;
        }
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

  // The native SDK returns a live track even when ScreenCaptureKit fails.
  // Do not publish or claim the screen until the capturer delivers a frame.
  static Future<void> _waitForFrames(lk.LocalVideoTrack track) async {
    final renderer = rtc.RTCVideoRenderer();
    final frame = Completer<void>();
    try {
      await renderer.initialize();
      renderer.onFirstFrameRendered = () {
        if (!frame.isCompleted) frame.complete();
      };
      await renderer.setSrcObject(stream: track.mediaStream);
      await frame.future.timeout(const Duration(seconds: 8));
    } catch (_) {
      throw PlatformException(code: 'screenNoFrames');
    } finally {
      await renderer.dispose();
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
