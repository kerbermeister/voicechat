import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:matrix/matrix.dart';
import 'call_probe.dart';
import 'direct_call.dart';
import 'voice_call.dart';
import 'screen_api.dart';
import 'screen_binding.dart';
import 'screen_controller.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'matrix_probe.dart';
import 'user_action_error.dart';

class CallInvitation {
  final Room room;
  final String session;
  final String sender;
  final DateTime created;
  final bool video;
  CallInvitation(
    this.room,
    this.session,
    this.sender,
    this.created, {
    this.video = false,
  });
}

/// Foreground invitations are encrypted Matrix messages; push/control service is a separate milestone.
class CallController extends ChangeNotifier
    with WidgetsBindingObserver
    implements WebRTCDelegate {
  final Client client;
  final String tokenUrl;
  final String mediaUrl;
  final void Function(String) report;
  final invitations = <String, CallInvitation>{};
  final declined = <String>{};
  VoiceCall? active;
  ScreenShareController? screen;
  VoiceCall? _screenCall;
  bool _screenChecking = false;
  final _screenParties = ScreenCallParties();
  StreamSubscription<List<BasicEventWithSender>>? _screenSignals;
  Room? dialingRoom;
  String? dialError;
  bool starting = false;
  int _dialGeneration = 0;
  final _recordedEnds = <String>{};
  late final VoIP voip;
  final directInvitations = <DirectCall>[];
  final _directCalls = <String, DirectCall>{};
  StreamSubscription<Event>? _events;
  Timer? _expiry;
  Timer? _ringTimeout;
  bool _closed = false;
  String? _resumeCamera;
  Future<void> _cameraLifecycle = Future.value();
  static const _nativeCalls = MethodChannel('voicechat/calls');
  Future<void>? _backgroundUpdate;
  bool _backgroundActive = false;
  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  CallController(this.client, this.tokenUrl, this.mediaUrl, this.report) {
    WidgetsBinding.instance.addObserver(this);
    if (_android) {
      _nativeCalls.setMethodCallHandler((call) async {
        if (call.method == 'end') {
          await end();
        } else if (call.method == 'backgroundUnavailable') {
          report(
            'Фоновый режим звонка недоступен. Оставьте приложение открытым.',
          );
        } else {
          throw MissingPluginException();
        }
      });
    }
    _screenSignals = client.onCallEvents.stream.listen(_screenParties.observe);
    voip = VoIP(client, this);
    _events = client.onTimelineEvent.stream.listen(receive);
    _expiry = Timer.periodic(const Duration(seconds: 5), (_) {
      invitations.removeWhere(
        (_, call) => DateTime.now().difference(call.created).inMinutes >= 10,
      );
      _refresh();
    });
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kIsWeb || _closed) return;
    final call = active;
    if (call == null || call.isClosed || !call.video) return;
    if (state == AppLifecycleState.inactive && call.cameraEnabled) {
      _resumeCamera = call.session;
      _cameraLifecycle = _cameraLifecycle
          .catchError((Object _) {})
          .then((_) => call.camera(false));
    } else if (state == AppLifecycleState.resumed &&
        _resumeCamera == call.session) {
      _resumeCamera = null;
      _cameraLifecycle = _cameraLifecycle.catchError((Object _) {}).then((
        _,
      ) async {
        if (active == call && !call.isClosed) await call.camera(true);
      });
    }
    unawaited(
      _cameraLifecycle.catchError((Object _) {
        report(
          'Не удалось переключить камеру после возврата. Включите её кнопкой звонка.',
        );
      }),
    );
  }

  void _refresh() {
    if (!_closed) unawaited(_prepareScreen());
    if (_android) {
      final call = active;
      final microphone = switch (call) {
        DirectCall() =>
          call.call.localUserMediaStream?.stream?.getAudioTracks().isNotEmpty ??
              false,
        CallProbe() =>
          call.media?.localParticipant?.audioTrackPublications.any(
                (publication) => publication.track != null,
              ) ??
              false,
        _ => false,
      };
      final keepAlive =
          !_closed &&
          call != null &&
          !call.isClosed &&
          (_backgroundActive || microphone);
      if (keepAlive != _backgroundActive) {
        _backgroundActive = keepAlive;
        _backgroundUpdate = (_backgroundUpdate ?? Future<void>.value()).then((
          _,
        ) async {
          try {
            await _nativeCalls.invokeMethod<void>('active', keepAlive);
          } catch (_) {
            report(
              'Фоновый режим звонка недоступен. Оставьте приложение открытым.',
            );
          }
        });
      }
    }
    if (!_closed) notifyListeners();
  }

  Future<void> _prepareScreen() async {
    final call = active;
    if (_screenChecking || call == _screenCall) return;
    if (call == null ||
        call.isClosed ||
        (call is DirectCall && call.call.state != CallState.kConnected) ||
        (call is DirectCall && _screenParties.curve(call) == null) ||
        (call is CallProbe && call.screenBindingLease == null)) {
      return;
    }
    _screenChecking = true;
    _screenCall = call;
    final previous = screen;
    screen = null;
    unawaited(previous?.close());
    previous?.dispose();
    final api = ScreenApi(tokenUrl, () => client.accessToken ?? '');
    ScreenShareController? next;
    try {
      final capability = await api.request('capabilities');
      if (_closed ||
          active != call ||
          call.isClosed ||
          capability['screen'] != true) {
        api.close();
        return;
      }
      next = ScreenShareController(
        call,
        api,
        mediaUrl,
        parties: _screenParties,
      );
      screen = next;
      await next.connect();
      if (_closed || active != call || call.isClosed) await next.close();
    } catch (_) {
      await next?.close();
      if (next == null) api.close();
      // Недоступность дополнительного экрана не завершает основной звонок.
    } finally {
      _screenChecking = false;
      if (!_closed) notifyListeners();
    }
  }

  void receive(Event event) {
    final content = event.content;
    if (!event.room.encrypted ||
        event.redacted ||
        content['msgtype'] != 'dev.voicechat.call') {
      return;
    }
    final id = content['session'];
    if (id is! String || !RegExp(r'^[a-z0-9]{32}$').hasMatch(id)) return;
    final age = DateTime.now().difference(event.originServerTs);
    if (age.isNegative || age.inMinutes >= 10) return;
    if (content['action'] == 'invite' &&
        event.senderId != client.userID &&
        !declined.contains(id)) {
      invitations[id] = CallInvitation(
        event.room,
        id,
        event.senderId,
        event.originServerTs,
        video: content['video'] == true,
      );
    } else if (content['action'] == 'decline' &&
        active?.session == id &&
        event.room.isDirectChat &&
        event.senderId != client.userID) {
      unawaited(active!.close());
      report('Собеседник отклонил вызов.');
    } else if (content['action'] == 'end') {
      // Only the initiating user can cancel their invitation.
      if (invitations[id]?.sender == event.senderId) invitations.remove(id);
      if (active?.session == id &&
          event.room.isDirectChat &&
          event.senderId != client.userID) {
        unawaited(active!.close());
      }
    }
    _refresh();
  }

  Future<void> _signal(
    Room room,
    String id,
    String action, {
    Duration? duration,
    bool video = false,
  }) async {
    await authorizedDevices(room).timeout(const Duration(seconds: 8));
    await room.client.encryption!.keyManager.clearOrUseOutboundGroupSession(
      room.id,
      wipe: true,
    );
    await room.sendEvent({
      'msgtype': 'dev.voicechat.call',
      'body': action == 'invite'
          ? video
                ? 'Видеозвонок'
                : 'Голосовой звонок'
          : action == 'decline'
          ? 'Вызов отклонён'
          : video
          ? 'Видеозвонок завершён'
          : 'Звонок завершён',
      'video': video,
      'action': action,
      'session': id,
      if (duration != null && duration > Duration.zero)
        'duration_ms': duration.inMilliseconds,
    });
  }

  Future<void> start(
    Room room, {
    CallInvitation? invitation,
    bool video = false,
  }) async {
    video = invitation?.video ?? video;
    if (starting) throw UserActionError('Вызов уже запускается.');
    if (active != null && !active!.isClosed) {
      throw UserActionError('Сначала завершите текущий звонок.');
    }
    starting = true;
    dialingRoom = room;
    dialError = null;
    final generation = ++_dialGeneration;
    _refresh();
    try {
      if (room.isDirectChat && invitation == null) {
        final devices = await authorizedDevices(room);
        final users = devices
            .map((d) => d.userId)
            .where((u) => u != client.userID)
            .toSet();
        if (users.length != 1) {
          throw UserActionError(
            'Для личного звонка нужен один собеседник, вступивший в чат.',
          );
        }
        if (generation != _dialGeneration || _closed) return;
        final session = await voip.inviteToCall(
          room,
          video ? CallType.kVideo : CallType.kVoice,
          userId: users.single,
        );
        active = _directCalls[session.callId]!;
        if (generation != _dialGeneration || _closed) {
          await active!.close();
          return;
        }
        await (active! as DirectCall).authorize();
        (active! as DirectCall).monitor();
        if (video) await active!.setVideoQuality(active!.videoQuality);
        _ringTimeout?.cancel();
        final call = active!;
        _ringTimeout = Timer(const Duration(seconds: 45), () {
          if (active == call &&
              !call.isClosed &&
              call.duration == Duration.zero) {
            unawaited(end());
            report('Нет ответа.');
          }
        });
        _refresh();
        return;
      }
      final id =
          invitation?.session ??
          List.generate(
            32,
            (_) => Random.secure().nextInt(16).toRadixString(16),
          ).join();
      final call = CallProbe(
        chat: room,
        session: id,
        tokenUrl: tokenUrl,
        livekitUrl: mediaUrl,
        status: report,
        changed: _refresh,
        video: video,
      );
      active = call;
      _refresh();
      try {
        await call.connect();
        if (generation != _dialGeneration || _closed) {
          await call.close();
          return;
        }
        if (invitation == null) {
          await _signal(room, id, 'invite', video: video);
          _ringTimeout?.cancel();
          _ringTimeout = Timer(const Duration(seconds: 45), () {
            if (active == call &&
                !call.isClosed &&
                call.participants.length == 1 &&
                call.duration == Duration.zero) {
              unawaited(end());
              report('Нет ответа. Звонок завершён.');
            }
          });
        }
        invitations.remove(id);
      } catch (_) {
        await call.close();
        rethrow;
      } finally {
        _refresh();
      }
    } catch (error) {
      if (generation == _dialGeneration) await active?.close();
      dialError = error is UserActionError
          ? error.message
          : 'Не удалось начать звонок. Проверьте сеть, микрофон и проверку устройств.';
      rethrow;
    } finally {
      starting = false;
      _refresh();
    }
  }

  Future<void> decline(CallInvitation invitation) async {
    declined.add(invitation.session);
    invitations.remove(invitation.session);
    _refresh();
    await _signal(
      invitation.room,
      invitation.session,
      'decline',
      video: invitation.video,
    );
  }

  Future<void> end() async {
    _dialGeneration++;
    dialingRoom = null;
    dialError = null;
    final call = active;
    if (call == null) {
      _refresh();
      return;
    }
    _ringTimeout?.cancel();
    final screenClose = screen?.close();
    await call.close(); // Release microphone even if signalling is offline.
    await screenClose;
    _refresh();
    if (call is DirectCall) {
      await _recordDirectEnd(call);
      return;
    }
    try {
      await _signal(
        call.chat,
        call.session,
        'end',
        duration: call.duration,
        video: call.video,
      );
    } catch (_) {
      report('Вы вышли из звонка. Сеть недоступна для уведомления участников.');
    }
  }

  Future<void> _recordDirectEnd(DirectCall call) async {
    if (call.call.direction != CallDirection.kOutgoing ||
        !_recordedEnds.add(call.session)) {
      return;
    }
    try {
      await authorizedDevices(call.chat).timeout(const Duration(seconds: 8));
      await call.chat.sendEvent({
        'msgtype': 'dev.voicechat.call_summary',
        'body': call.duration == Duration.zero
            ? 'Нет ответа / вызов завершён'
            : call.video
            ? 'Видеозвонок завершён'
            : 'Звонок завершён',
        'video': call.video,
        'duration_ms': call.duration.inMilliseconds,
        'session': call.session,
      }, txid: 'call-end-${call.session}');
    } catch (_) {
      report('Звонок завершён. Событие не удалось записать в историю.');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    _expiry?.cancel();
    _ringTimeout?.cancel();
    mediaDevices.ondevicechange =
        null; // Release the SDK callback retaining this client after lock/logout.
    await _events?.cancel();
    await _screenSignals?.cancel();
    final screenClose = screen?.close();
    await active?.close();
    await screenClose;
    screen?.dispose();
    for (final call in _directCalls.values) {
      await call.close();
    }
    _refresh();
    if (_backgroundUpdate != null) await _backgroundUpdate;
    if (_android) _nativeCalls.setMethodCallHandler(null);
    dispose();
  }

  Future<void> acceptDirect(DirectCall call) async {
    if (active != null && !active!.isClosed) {
      throw UserActionError('Сначала завершите текущий звонок.');
    }
    active = call;
    try {
      await call.answer();
    } catch (_) {
      await call.close();
      rethrow;
    }
    directInvitations.remove(call);
    _refresh();
  }

  Future<void> declineDirect(DirectCall call) async {
    await call.close();
    directInvitations.remove(call);
    _refresh();
  }

  @override
  get mediaDevices => rtc.navigator.mediaDevices;
  @override
  Future<rtc.RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> configuration, [
    Map<String, dynamic> constraints = const {},
  ]) {
    // shortcut: force TURN in loopback tests; real deployments use ICE's direct-first policy.
    if (const {
      'localhost',
      '127.0.0.1',
      '::1',
    }.contains(client.homeserver?.host)) {
      configuration = {...configuration, 'iceTransportPolicy': 'relay'};
    }
    return rtc.createPeerConnection(configuration, constraints);
  }

  @override
  bool get isWeb => kIsWeb;
  @override
  bool get canHandleNewCall => !_closed && (active == null || active!.isClosed);
  @override
  EncryptionKeyProvider? get keyProvider => null;
  @override
  Future<void> playRingtone() async {}
  @override
  Future<void> stopRingtone() async {}
  @override
  Future<void> registerListeners(CallSession session) async {
    final call = DirectCall(session, _refresh, report);
    _directCalls[session.callId] = call;
    if (session.direction == CallDirection.kIncoming) {
      try {
        await call.authorize().timeout(const Duration(seconds: 8));
      } catch (_) {
        await call.close();
        report('Входящий вызов отклонён: устройства не проверены.');
      }
    }
  }

  @override
  Future<void> handleNewCall(CallSession session) async {
    final call = _directCalls[session.callId]!;
    if (_closed ||
        (!canHandleNewCall && active != call) ||
        !session.room.encrypted ||
        !session.room.isDirectChat) {
      await call.close();
      return;
    }
    if (call.isClosed || _closed) return;
    if (session.direction == CallDirection.kIncoming) {
      directInvitations.add(call);
    } else {
      active = call;
    }
    _refresh();
  }

  @override
  Future<void> handleCallEnded(CallSession session) async {
    directInvitations.removeWhere((c) => c.session == session.callId);
    await _directCalls[session.callId]?.close();
    final call = _directCalls[session.callId];
    if (call != null) await _recordDirectEnd(call);
    _refresh();
  }

  @override
  Future<void> handleMissedCall(CallSession session) async {
    report('Пропущенный звонок');
  }

  @override
  Future<void> handleNewGroupCall(GroupCallSession groupCall) async {}
  @override
  Future<void> handleGroupCallEnded(GroupCallSession groupCall) async {}
}
