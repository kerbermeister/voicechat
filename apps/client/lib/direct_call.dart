import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:matrix/matrix.dart' as mx;
import 'matrix_probe.dart';
import 'voice_call.dart';
import 'call_quality.dart';
import 'camera_capture.dart';

/// Matrix authenticates SDP/ICE; WebRTC supplies DTLS-SRTP end to end, including over TURN.
class DirectCall implements VoiceCall {
  final mx.CallSession call;
  final void Function() changed;
  final void Function(String) report;
  final _renderers = <rtc.RTCVideoRenderer>[];
  rtc.RTCVideoRenderer? localVideo;
  rtc.RTCVideoRenderer? remoteVideo;
  rtc.RTCRtpSender? _cameraSender;
  String _cameraFacing = 'user';
  bool get mirrorLocalVideo => _cameraFacing == 'user';
  final _streams = <mx.WrappedMediaStream, rtc.RTCVideoRenderer>{};
  final _renderedTracks = <rtc.RTCVideoRenderer, List<String>>{};
  final _statistics = CallStatistics();
  @override
  VideoQuality videoQuality = VideoQuality.auto;
  @override
  CallQuality quality = CallQuality.unknown;
  @override
  bool get video => call.type == mx.CallType.kVideo;
  @override
  bool get cameraEnabled => video && !call.isLocalVideoMuted;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _authorizationTimer;
  Set<String>? _devices;
  bool _checking = false;
  bool _closed = false;
  DateTime _authorizedAt = DateTime.now();
  final _clock = Stopwatch();
  @override
  Duration get duration => _clock.elapsed;
  DirectCall(this.call, this.changed, this.report) {
    _subscriptions.add(
      call.onCallStateChanged.stream.listen((_) {
        // onTrack can add audio after video, without emitting another onStreamAdd.
        for (final entry in _streams.entries) {
          _updateRenderer(entry.key, entry.value);
        }
        if (call.state == mx.CallState.kConnected) _clock.start();
        changed();
        if (isClosed) unawaited(close());
      }),
    );
    _subscriptions.add(
      call.onStreamAdd.stream.listen((stream) {
        changed();
        if (stream.isLocal() && !video) return;
        unawaited(_render(stream));
      }),
    );
  }
  @override
  mx.Room get chat => call.room;
  @override
  String get session => call.callId;
  @override
  bool get isClosed =>
      _closed ||
      call.state == mx.CallState.kEnded ||
      call.state == mx.CallState.kEnding;
  @override
  bool get muted => call.isMicrophoneMuted;
  @override
  List<String> get participants => [
    chat.client.userID!,
    if (call.remoteUserId != null) call.remoteUserId!,
  ];
  @override
  String get connection => quality == CallQuality.lost && !isClosed
      ? 'Восстанавливаем связь'
      : switch (call.state) {
          mx.CallState.kConnected =>
            video ? 'Видеозвонок · разговор' : 'Голосовой звонок · разговор',
          mx.CallState.kRinging || mx.CallState.kInviteSent => 'Ожидаем ответ',
          mx.CallState.kEnded || mx.CallState.kEnding => 'Звонок завершён',
          _ => 'Подключаем звонок',
        };
  Future<void> _render(mx.WrappedMediaStream stream) async {
    if (!kIsWeb && !video) {
      return; // Native WebRTC renders audio itself; web needs a media element.
    }
    final renderer = rtc.RTCVideoRenderer();
    try {
      await renderer.initialize();
      if (_closed) {
        await renderer.dispose();
        return;
      }
      _updateRenderer(stream, renderer);
      // Native muting controls the microphone and rejects remote streams; web muting only silences preview playback.
      if (kIsWeb) renderer.muted = stream.isLocal();
      _renderers.add(renderer);
      _streams[stream] = renderer;
      if (video) {
        if (stream.isLocal()) {
          localVideo = renderer;
        } else {
          remoteVideo = renderer;
        }
        changed();
      }
    } catch (_) {
      await renderer.dispose();
      await close();
      report('Не удалось включить аудио.');
    }
  }

  void _updateRenderer(
    mx.WrappedMediaStream stream,
    rtc.RTCVideoRenderer renderer,
  ) {
    final tracks =
        stream.stream?.getTracks().map((track) => track.id!).toList() ??
        <String>[];
    tracks.sort();
    if (!listEquals(_renderedTracks[renderer], tracks)) {
      renderer.srcObject = stream.stream;
      _renderedTracks[renderer] = tracks;
    }
  }

  Future<void> authorize() async {
    final devices = (await authorizedDevices(chat))
        .map(
          (d) => '${d.userId}/${d.deviceId}/${d.ed25519Key}/${d.curve25519Key}',
        )
        .toSet();
    if (_devices != null &&
        (_devices!.length != devices.length ||
            !_devices!.containsAll(devices))) {
      throw CallAccessChanged();
    }
    _devices = devices;
    _authorizedAt = DateTime.now();
  }

  void monitor() {
    _authorizationTimer ??= Timer.periodic(const Duration(seconds: 3), (_) {
      if (_checking || _closed) return;
      _checking = true;
      unawaited(
        authorize()
            .then((_) async {
              try {
                quality = _statistics.read(await call.pc?.getStats() ?? []);
              } catch (_) {
                quality = CallQuality.unknown;
              }
              changed();
            })
            .timeout(const Duration(seconds: 5))
            .catchError((Object error) async {
              quality = CallQuality.lost;
              if (!callAccessDenied(error) &&
                  DateTime.now().difference(_authorizedAt) <
                      const Duration(seconds: 15)) {
                changed();
                return;
              }
              await close();
              report(
                'Звонок завершён: доступ изменён или не удалось его проверить.',
              );
            })
            .whenComplete(() => _checking = false),
      );
    });
  }

  Future<void> answer() async {
    await authorize();
    await call.answer();
    if (video) await setVideoQuality(videoQuality);
    monitor();
    changed();
  }

  @override
  Future<void> mute(bool value) async {
    await call.setMicrophoneMuted(value);
    changed();
  }

  @override
  Future<void> camera(bool enabled) async {
    if (!video || isClosed || enabled == cameraEnabled) return;
    final stream = call.localUserMediaStream?.stream;
    if (stream == null) throw StateError('Camera stream unavailable');
    final senders = await call.pc!.getSenders();
    _cameraSender ??= senders
        .where((s) => s.track?.kind == 'video')
        .firstOrNull;
    if (_cameraSender == null) throw StateError('Camera sender unavailable');
    if (!enabled) {
      await call.setLocalVideoMuted(true);
      await replaceCameraTrack(_cameraSender!, null);
      for (final track in stream.getVideoTracks()) {
        await stream.removeTrack(track);
        await track.stop();
      }
    } else {
      final capture = await captureCamera(_cameraFacing, videoQuality);
      try {
        if (isClosed) throw StateError('Call ended during camera permission');
        final track = capture.getVideoTracks().single;
        await stream.addTrack(track);
        await replaceCameraTrack(_cameraSender!, track);
        // Capture and sender replacement are complete; do not reacquire the
        // default camera/microphone through Matrix's audio-only upgrade path.
        call.localUserMediaStream?.setVideoMuted(false);
        await call.updateMuteStatus();
      } catch (_) {
        call.localUserMediaStream?.setVideoMuted(true);
        try {
          await replaceCameraTrack(_cameraSender!, null);
        } catch (_) {
          // A closed peer connection cannot detach, but capture still must stop.
        } finally {
          for (final track in capture.getTracks()) {
            try {
              await stream.removeTrack(track);
            } finally {
              await track.stop();
            }
          }
        }
        rethrow;
      } finally {
        for (final track in capture.getTracks()) {
          await capture.removeTrack(track);
        }
        await capture.dispose();
      }
    }
    localVideo?.srcObject = stream;
    changed();
  }

  @override
  Future<void> switchCamera() async {
    if (!cameraEnabled) return;
    final track = call.localUserMediaStream!.stream!.getVideoTracks().single;
    final current = kIsWeb
        ? track.getSettings()['facingMode'] as String? ?? _cameraFacing
        : _cameraFacing;
    final next = current == 'environment' ? 'user' : 'environment';
    if (!kIsWeb) {
      if (!await rtc.Helper.switchCamera(track)) {
        throw StateError('Camera switch unavailable');
      }
      _cameraFacing = next;
      changed();
      return;
    }
    // iOS needs the previous camera released; enumeration may expose only one device.
    await camera(false);
    _cameraFacing = next;
    try {
      await camera(true);
    } catch (_) {
      _cameraFacing = current;
      try {
        await camera(true);
      } catch (_) {
        report('Камера выключена. Проверьте разрешение и включите её снова.');
      }
      rethrow;
    }
  }

  @override
  Future<void> setVideoQuality(VideoQuality value) async {
    if (!video || isClosed) return;
    for (final sender in await call.pc?.getSenders() ?? <rtc.RTCRtpSender>[]) {
      if (sender.track?.kind != 'video') continue;
      final parameters = sender.parameters;
      for (final encoding in parameters.encodings ?? <rtc.RTCRtpEncoding>[]) {
        encoding.maxBitrate = value.bitrate;
        encoding.maxFramerate = value.fps;
        final width = sender.track!.getSettings()['width'] as num? ?? 1280;
        final height = sender.track!.getSettings()['height'] as num? ?? 720;
        encoding.scaleResolutionDownBy = math
            .max(1, math.max(width / value.width, height / value.height))
            .toDouble();
      }
      if (!await sender.setParameters(parameters)) {
        throw StateError('Video quality was not applied');
      }
    }
    videoQuality = value;
    changed();
  }

  Future<int> receivedAudioPackets() async {
    final reports = await call.pc?.getStats() ?? [];
    var count = 0;
    for (final stat in reports) {
      if (stat.type == 'inbound-rtp' &&
          (stat.values['kind'] == 'audio' ||
              stat.values['mediaType'] == 'audio')) {
        count += (stat.values['packetsReceived'] as num? ?? 0).toInt();
      }
    }
    return count;
  }

  Future<bool> hasSecureRelay() async {
    final reports = await call.pc?.getStats() ?? [];
    final secure = reports.any(
      (r) => r.type == 'transport' && r.values['dtlsState'] == 'connected',
    );
    final relays = reports
        .where(
          (r) =>
              r.type == 'local-candidate' &&
              r.values['candidateType'] == 'relay',
        )
        .map((r) => r.id)
        .toSet();
    return secure &&
        reports.any(
          (r) =>
              r.type == 'candidate-pair' &&
              r.values['state'] == 'succeeded' &&
              r.values['nominated'] == true &&
              relays.contains(r.values['localCandidateId']),
        );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _clock.stop();
    _authorizationTimer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    try {
      if (call.state != mx.CallState.kEnded &&
          call.state != mx.CallState.kEnding) {
        await call.hangup(reason: mx.CallErrorCode.userHangup);
      }
    } finally {
      for (final renderer in _renderers) {
        renderer.srcObject = null;
        await renderer.dispose();
      }
      _streams.clear();
      _renderedTracks.clear();
      changed();
    }
  }
}
