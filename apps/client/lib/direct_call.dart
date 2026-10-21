import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:matrix/matrix.dart' as mx;
import 'matrix_probe.dart';
import 'voice_call.dart';

/// Matrix authenticates SDP/ICE; WebRTC supplies DTLS-SRTP end to end, including over TURN.
class DirectCall implements VoiceCall {
  final mx.CallSession call;
  final void Function() changed;
  final void Function(String) report;
  final _renderers = <rtc.RTCVideoRenderer>[];
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _authorizationTimer;
  Set<String>? _devices;
  bool _checking = false;
  bool _closed = false;
  DirectCall(this.call, this.changed, this.report) {
    _subscriptions.add(
      call.onCallStateChanged.stream.listen((_) {
        changed();
        if (isClosed) unawaited(close());
      }),
    );
    _subscriptions.add(
      call.onStreamAdd.stream.listen((stream) {
        if (stream.isLocal()) return;
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
  String get connection => switch (call.state) {
    mx.CallState.kConnected => 'WebRTC · защищённое аудио',
    mx.CallState.kRinging || mx.CallState.kInviteSent => 'Ожидаем ответ',
    mx.CallState.kEnded || mx.CallState.kEnding => 'Звонок завершён',
    _ => 'Подключение WebRTC',
  };
  Future<void> _render(mx.WrappedMediaStream stream) async {
    if (!kIsWeb) {
      return; // Native WebRTC renders audio itself; web needs a media element.
    }
    final renderer = rtc.RTCVideoRenderer();
    try {
      await renderer.initialize();
      if (_closed) {
        await renderer.dispose();
        return;
      }
      renderer.srcObject = stream.stream;
      renderer.muted = false;
      _renderers.add(renderer);
    } catch (_) {
      await renderer.dispose();
      await close();
      report('Не удалось включить аудио.');
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
      throw StateError('Call authorization changed');
    }
    _devices = devices;
  }

  void monitor() {
    _authorizationTimer ??= Timer.periodic(const Duration(seconds: 3), (_) {
      if (_checking || _closed) return;
      _checking = true;
      unawaited(
        authorize()
            .timeout(const Duration(seconds: 5))
            .catchError((Object _) async {
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
    monitor();
    changed();
  }

  @override
  Future<void> mute(bool value) async {
    await call.setMicrophoneMuted(value);
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
      changed();
    }
  }
}
