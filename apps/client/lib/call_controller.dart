import 'call_audio.dart';
import 'personal_room.dart';
import 'dart:async';
import 'dart:math';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:matrix/matrix.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'call_probe.dart';
import 'call_devices.dart';
import 'direct_call.dart';
import 'voice_call.dart';
import 'screen_api.dart';
import 'route_transport.dart';
import 'media_routes.dart';
import 'screen_binding.dart';
import 'screen_controller.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'matrix_probe.dart';
import 'user_action_error.dart';
import 'call_push.dart';
import 'group_calls.dart';
import 'call_page_exit.dart';

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
  final Future<void> Function()? beforeMedia;
  final invitations = <String, CallInvitation>{};
  final declined = <({String room, String session})>{};
  final _endedInvitations =
      <({String room, String sender, String session}), DateTime>{};
  late final CallDevices devices;
  late final GroupCalls groups;
  VoiceCall? active;
  String? _activeInitiator;
  final audio = CallAudio();
  ScreenShareController? screen;
  VoiceCall? _screenCall;
  bool _screenChecking = false;
  DateTime? _screenRetryAt;
  final _screenParties = ScreenCallParties();
  StreamSubscription<List<BasicEventWithSender>>? _callSignals;
  Room? dialingRoom;
  String? dialError;
  bool starting = false;
  bool _dialPending = false;
  int _dialGeneration = 0;
  final _recordedEnds = <({String room, String session})>{};
  late final VoIP voip;
  final directInvitations = <DirectCall>[];
  final _directCalls = <CallSession, DirectCall>{};
  StreamSubscription<Event>? _events;
  StreamSubscription<dynamic>? _lateEvents;
  Timer? _expiry;
  Timer? _ringTimeout;
  Timer? _pushPoll;
  String? _outgoingPush;
  bool _pushPolling = false;
  late final _push = CallPush(client, tokenUrl);
  bool _closed = false;
  late final void Function() _stopPageExit;
  String? _resumeCamera;
  AppLifecycleState? _lifecycleState;
  Future<void> _cameraLifecycle = Future.value();
  static const _nativeCalls = MethodChannel('voicechat/calls');
  Future<void>? _backgroundUpdate;
  bool _backgroundActive = false;
  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _nativeCallActions =>
      !kIsWeb &&
      const {
        TargetPlatform.android,
        TargetPlatform.macOS,
      }.contains(defaultTargetPlatform);
  CallController(
    this.client,
    this.tokenUrl,
    this.mediaUrl,
    this.report, {
    List<BasicEventWithSender> initialEvents = const [],
    this.beforeMedia,
  }) {
    devices = CallDevices(client, _refresh);
    groups = GroupCalls(client, tokenUrl, _refresh);
    _stopPageExit = listenCallPageExit(() {
      unawaited(_leaveView().catchError((Object _) {}));
    });
    WidgetsBinding.instance.addObserver(this);
    if (_nativeCallActions) {
      _nativeCalls.setMethodCallHandler((call) async {
        if (call.method == 'end') {
          await _leaveView();
        } else if (call.method == 'backgroundUnavailable') {
          report(
            'Фоновый режим звонка недоступен. Оставьте приложение открытым.',
          );
        } else {
          throw MissingPluginException();
        }
      });
    }
    _callSignals = client.onCallEvents.stream.listen((events) {
      _screenParties.observe(events);
      for (final event in events.whereType<Event>()) {
        receive(event);
      }
    });
    voip = RoutedVoIP(client, this);
    _events = client.onTimelineEvent.stream.listen(receive);
    // Matrix 14.2 does not emit late-decrypted messages on onTimelineEvent.
    // Listen only to that missing update, without replaying historical calls.
    // ignore: deprecated_member_use
    _lateEvents = client.onEvent.stream.listen((update) {
      if (update.type != EventUpdateType.decryptedTimelineQueue) return;
      final room = client.getRoomById(update.roomID);
      if (room != null) receive(Event.fromJson(update.content, room));
    });
    _expiry = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(groups.refresh());
      invitations.removeWhere(
        (_, call) =>
            DateTime.now().difference(call.created) >=
            const Duration(seconds: 45),
      );
      _refresh();
    });
    if (initialEvents.isNotEmpty) {
      scheduleMicrotask(() {
        if (!_closed) client.onCallEvents.add(List.of(initialEvents));
      });
    }
  }
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    // Keep Matrix and the engine alive long enough to deliver hangup on Cmd-Q.
    // A network outage must not prevent the operating system from quitting.
    try {
      await close().timeout(const Duration(seconds: 5));
    } catch (_) {
      debugPrint('Call teardown did not finish before application exit');
    }
    return AppExitResponse.exit;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closed) return;
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      unawaited(groups.refresh());
      unawaited(routeTransportOf(client.httpClient)?.coordinator?.refresh());
      unawaited(screen?.poll());
      _refresh();
    }
    if (kIsWeb) return;
    final call = active;
    if (call == null || call.isClosed || !call.video) return;
    if (state != AppLifecycleState.resumed &&
        (call.cameraEnabled || _resumeCamera == call.session)) {
      _resumeCamera = call.session;
      _cameraLifecycle = _cameraLifecycle
          .catchError((Object _) {})
          .then((_) => call.camera(false));
    } else if (state == AppLifecycleState.resumed &&
        _resumeCamera == call.session) {
      _cameraLifecycle = _cameraLifecycle.catchError((Object _) {}).then((
        _,
      ) async {
        if (active == call &&
            !call.isClosed &&
            _lifecycleState == AppLifecycleState.resumed &&
            _resumeCamera == call.session) {
          await call.camera(true);
          if (_lifecycleState == AppLifecycleState.resumed) {
            _resumeCamera = null;
          }
        }
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
    unawaited(audio.sync(active).catchError((Object _) {}));
    devices.update(active);
    invitations.removeWhere(
      (id, invitation) =>
          invitation.room.membership != Membership.join ||
          devices.answered(invitation.room.id, id),
    );
    directInvitations.removeWhere(
      (call) => call.isClosed || devices.answered(call.chat.id, call.session),
    );
    final pending =
        starting ||
        directInvitations.isNotEmpty ||
        invitations.isNotEmpty ||
        devices.remote.isNotEmpty;
    // A new call must not restore the previous call's timer/error on dismissal.
    if (pending && active?.isClosed == true) {
      active = null;
      if (!starting) {
        dialError = null;
        dialingRoom = null;
      }
    }
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
    if (_screenChecking ||
        (call == _screenCall &&
            !(screen?.isClosed == true && screen!.reconnectAllowed)) ||
        (_screenRetryAt != null && DateTime.now().isBefore(_screenRetryAt!))) {
      return;
    }
    if (call == null ||
        call.isClosed ||
        (call is! DirectCall && call is! CallProbe) ||
        (call is DirectCall && call.call.state != CallState.kConnected) ||
        (call is DirectCall && _screenParties.curve(call) == null) ||
        (call is CallProbe &&
            (call.screenBindingLease == null ||
                call.media?.connectionState != lk.ConnectionState.connected))) {
      return;
    }
    _screenChecking = true;
    _screenCall = call;
    final previous = screen;
    screen = null;
    await previous?.close();
    previous?.dispose();
    final api = ScreenApi(
      tokenUrl,
      () => client.accessToken ?? '',
      client: routeTransportOf(client.httpClient)?.fork(),
    );
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
      if (previous?.reconnectAllowed == true) {
        next.notice =
            'Демонстрация переподключена после паузы. Для своего экрана нажмите «Показать экран».';
      }
      await next.connect();
      if (_closed || active != call || call.isClosed) await next.close();
    } catch (_) {
      await next?.close();
      if (next == null) api.close();
      if (next?.hasBinding != true) {
        _screenCall = null;
        _screenRetryAt = DateTime.now().add(const Duration(seconds: 5));
      }
      // Недоступность дополнительного экрана не завершает основной звонок.
    } finally {
      _screenChecking = false;
      if (!_closed) notifyListeners();
    }
  }

  bool _ownDeviceEvent(Event event) {
    final source = event.originalSource;
    final curve = source?.content['sender_key'];
    return event.senderId == client.userID &&
        source?.senderId == client.userID &&
        source?.type == EventTypes.Encrypted &&
        curve is String &&
        devices.verifiedOwnDevice(curve) != null;
  }

  Future<void> _endOwnIncoming(DirectCall call) async {
    // The SDK's remote-party guard ignores hangup from our other devices.
    // Terminate locally without echoing a new hangup back into the room.
    await call.call.terminate(
      CallParty.kRemote,
      CallErrorCode.userHangup,
      true,
    );
    await call.close();
    _refresh();
  }

  void receive(Event event) {
    if (_closed || !event.room.encrypted || event.redacted) return;
    final content = event.content;
    // Homeserver timestamps may lead the local clock slightly.
    final age = DateTime.now().difference(event.originServerTs);
    if (age < const Duration(minutes: -1) ||
        age >= const Duration(minutes: 10)) {
      return;
    }
    if (event.room.isDirectChat &&
        {EventTypes.CallHangup, EventTypes.CallReject}.contains(event.type) &&
        _ownDeviceEvent(event)) {
      final session = content['call_id'];
      if (session is! String || session.isEmpty || session.length > 128) return;
      _dismissInvitation(event.room.id, session);
      final pending = directInvitations
          .where(
            (call) => call.chat.id == event.room.id && call.session == session,
          )
          .toList();
      directInvitations.removeWhere(pending.contains);
      for (final call in pending) {
        unawaited(
          _endOwnIncoming(call).catchError((Object _) {
            report(
              'Не удалось завершить входящий вызов после отказа на другом устройстве.',
            );
          }),
        );
      }
      _refresh();
      return;
    }
    if (content['msgtype'] != 'dev.voicechat.call') return;
    final id = content['session'];
    if (id is! String || !RegExp(r'^[a-z0-9]{32}$').hasMatch(id)) return;
    _endedInvitations.removeWhere(
      (_, time) =>
          DateTime.now().difference(time) >= const Duration(minutes: 10),
    );
    final invitationKey = (
      room: event.room.id,
      sender: event.senderId,
      session: id,
    );
    if (content['action'] == 'invite' &&
        event.room.membership == Membership.join &&
        age < const Duration(seconds: 45) &&
        !_endedInvitations.containsKey(invitationKey) &&
        event.senderId != client.userID &&
        !declined.contains((room: event.room.id, session: id)) &&
        !devices.answered(event.room.id, id)) {
      invitations[id] = CallInvitation(
        event.room,
        id,
        event.senderId,
        event.originServerTs,
        video: content['video'] == true,
      );
    } else if (content['action'] == 'decline' && _ownDeviceEvent(event)) {
      _dismissInvitation(event.room.id, id);
    } else if (content['action'] == 'decline' &&
        active?.session == id &&
        active?.chat.id == event.room.id &&
        event.room.isDirectChat &&
        event.senderId != client.userID) {
      unawaited(active!.close());
      report('Собеседник отклонил вызов.');
    } else if (content['action'] == 'end') {
      _endedInvitations[invitationKey] = event.originServerTs;
      if (_endedInvitations.length > 128) {
        _endedInvitations.remove(_endedInvitations.keys.first);
      }
      // Only the initiating user can cancel their invitation.
      if (invitations[id]?.sender == event.senderId &&
          invitations[id]?.room.id == event.room.id) {
        invitations.remove(id);
      }
      if (active?.session == id &&
          active?.chat.id == event.room.id &&
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
    String? initiator,
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
          : action == 'leave'
          ? 'Участник вышел из звонка'
          : video
          ? 'Видеозвонок завершён'
          : 'Звонок завершён',
      'video': video,
      'action': action,
      if (initiator != null || action == 'invite')
        'dev.voicechat.call_initiator': initiator ?? client.userID,
      'session': id,
      if (duration != null && duration > Duration.zero)
        'duration_ms': duration.inMilliseconds,
    });
  }

  Future<void> _invitePush(VoiceCall call) async {
    _outgoingPush = call.session;
    try {
      await _push.invite(call.session, call.chat.id, video: call.video);
      if (_closed || active != call || call.isClosed) {
        await _push.endOutgoing(call.session);
        return;
      }
      _pushPoll?.cancel();
      _pushPoll = Timer.periodic(const Duration(seconds: 2), (timer) async {
        if (_pushPolling) return;
        if (_closed || active != call || call.isClosed) {
          timer.cancel();
          if (_outgoingPush == call.session) await _endPush();
          return;
        }
        _pushPolling = true;
        try {
          final state = await _push.request('status', call.session);
          if (_closed || active != call || call.isClosed) return;
          if (state['declined'] == true ||
              (state['ended'] == true && call.duration == Duration.zero)) {
            await end();
          } else if (state['answered'] == true ||
              call.duration > Duration.zero) {
            timer.cancel();
          }
        } catch (_) {
          // Matrix and the existing ring timeout remain available on push failure.
        } finally {
          _pushPolling = false;
        }
      });
    } catch (_) {
      report(
        'Фоновое уведомление не отправлено. Собеседник получит вызов при работающем приложении.',
      );
      await _push.endOutgoing(call.session);
    }
  }

  Future<void> _endPush() {
    final session = _outgoingPush;
    _outgoingPush = null;
    _pushPoll?.cancel();
    return session == null ? Future.value() : _push.endOutgoing(session);
  }

  Future<bool> _answerPush(String session) async {
    try {
      await _push.request('accept', session);
      return true;
    } on CallPushError catch (error) {
      // shortcut: older callers have no push record; remove after their migration.
      if (error.code == 'call_not_found' || error.code == 'fcm_unavailable') {
        return true;
      }
      report('Вызов уже завершён или принят на другом устройстве.');
      return false;
    } catch (_) {
      report('Не удалось проверить актуальность вызова. Попробуйте снова.');
      return false;
    }
  }

  Future<void> start(
    Room room, {
    CallInvitation? invitation,
    bool video = false,
  }) async {
    if (isPersonalRoom(room)) {
      throw UserActionError('В личной комнате звонки недоступны.');
    }
    video = invitation?.video ?? video;
    if (_dialPending || starting) {
      throw UserActionError(
        'Предыдущий запуск звонка ещё завершается. Повторите через несколько секунд.',
      );
    }
    if (active != null && !active!.isClosed) {
      throw UserActionError('Сначала завершите текущий звонок.');
    }
    _dialPending = true;
    starting = true;
    dialingRoom = room;
    dialError = null;
    final generation = ++_dialGeneration;
    String? existingSession;
    var rejoining = invitation != null;
    _refresh();
    try {
      if (invitation != null && !await _answerPush(invitation.session)) return;
      await beforeMedia?.call();
      if (!room.isDirectChat && invitation == null) {
        final ongoing = await groups.find(room);
        if (generation != _dialGeneration || _closed) return;
        if (ongoing != null) {
          existingSession = ongoing.session;
          video = ongoing.video;
          rejoining = true;
        }
      }
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
        final call = _directCalls[session]!;
        if (generation != _dialGeneration || _closed) {
          await call.close();
          return;
        }
        active = call;
        await call.authorize();
        if (generation != _dialGeneration || _closed || call.isClosed) {
          await call.close();
          return;
        }
        call.monitor();
        if (video) await call.setVideoQuality(call.videoQuality);
        if (generation != _dialGeneration || _closed || call.isClosed) return;
        _ringTimeout?.cancel();
        _ringTimeout = Timer(const Duration(seconds: 45), () {
          if (active == call &&
              !call.isClosed &&
              call.duration == Duration.zero) {
            unawaited(end());
            report('Нет ответа.');
          }
        });
        _refresh();
        unawaited(_invitePush(call));
        return;
      }
      final id =
          invitation?.session ??
          existingSession ??
          List.generate(
            32,
            (_) => Random.secure().nextInt(16).toRadixString(16),
          ).join();
      final call = CallProbe(
        chat: room,
        session: id,
        tokenUrl: tokenUrl,
        livekitUrl: mediaUrl,
        joinExisting: existingSession != null,
        status: report,
        changed: _refresh,
        video: video,
      );
      active = call;
      _activeInitiator =
          invitation?.sender ?? (rejoining ? null : client.userID);
      _refresh();
      try {
        await call.connect();
        if (generation != _dialGeneration || _closed) {
          await call.close();
          return;
        }
        if (!rejoining) {
          await _signal(room, id, 'invite', video: video);
          unawaited(_invitePush(call));
          if (generation != _dialGeneration || _closed || call.isClosed) return;
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
        if (rejoining) devices.accept(call);
        invitations.remove(id);
      } catch (_) {
        await call.close();
        rethrow;
      } finally {
        _refresh();
      }
    } catch (error) {
      if (generation != _dialGeneration || _closed) return;
      await active?.close();
      dialError = error is UserActionError
          ? error.message
          : 'Не удалось начать звонок. Проверьте сеть, микрофон и проверку устройств.';
      rethrow;
    } finally {
      _dialPending = false;
      starting = false;
      _refresh();
    }
  }

  void _dismissInvitation(String room, String session) {
    declined.add((room: room, session: session));
    if (declined.length > 128) declined.remove(declined.first);
    if (invitations[session]?.room.id == room) invitations.remove(session);
  }

  Future<void> decline(CallInvitation invitation) async {
    unawaited(
      _push
          .request('decline', invitation.session)
          .catchError((Object _) => <String, dynamic>{}),
    );
    _dismissInvitation(invitation.room.id, invitation.session);
    _refresh();
    await _signal(
      invitation.room,
      invitation.session,
      'decline',
      video: invitation.video,
      initiator: invitation.sender,
    );
  }

  Future<void> end() async {
    final pushEnd = _endPush();
    _dialGeneration++;
    starting = false;
    _ringTimeout?.cancel();
    dialingRoom = null;
    dialError = null;
    final call = active;
    final initiator = _activeInitiator;
    final othersRemain = call is CallProbe && call.participants.length > 1;
    if (call == null || call.isClosed) {
      _refresh();
      await pushEnd;
      return;
    }
    final screenClose = screen?.close();
    final callClose = call.close(); // Marks closed before asynchronous cleanup.
    final groupSignal = call is DirectCall
        ? null
        : _signal(
            call.chat,
            call.session,
            othersRemain ? 'leave' : 'end',
            initiator: initiator,
            duration: call.duration,
            video: call.video,
          ).catchError((Object _) {
            report(
              'Вы вышли из звонка. Сеть недоступна для уведомления участников.',
            );
          });
    _refresh(); // Stop ringback without waiting for network or media disposal.
    try {
      await Future.wait([
        pushEnd,
        callClose,
        if (screenClose != null) screenClose,
        if (groupSignal != null) groupSignal,
      ]);
    } finally {
      _refresh();
    }
    if (call is DirectCall) {
      await _recordDirectEnd(call);
      return;
    }
    unawaited(groups.refresh());
  }

  Future<void> _leaveView() async {
    await Future.wait([
      end(),
      for (final call in directInvitations.toList()) call.close(),
      for (final invitation in invitations.values.toList())
        decline(invitation).catchError((Object _) {}),
    ]);
  }

  Future<void> _recordDirectEnd(DirectCall call) async {
    if (call.call.direction != CallDirection.kOutgoing ||
        !_recordedEnds.add((room: call.chat.id, session: call.session))) {
      return;
    }
    try {
      await authorizedDevices(call.chat).timeout(const Duration(seconds: 8));
      await call.chat.sendEvent({
        'msgtype': 'dev.voicechat.call_summary',
        'dev.voicechat.call_initiator': client.userID,
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

  Future<void> close() => _closing ??= _close();

  Future<void>? _closing;
  Future<void> _close() async {
    _closed = true;
    _stopPageExit();
    _dialGeneration++;
    starting = false;
    WidgetsBinding.instance.removeObserver(this);
    _expiry?.cancel();
    _ringTimeout?.cancel();
    groups.close();
    mediaDevices.ondevicechange =
        null; // Release the SDK callback retaining this client after lock/logout.
    final mediaClosing = [
      _leaveView(),
      if (screen != null) screen!.close(),
      for (final call in {if (active != null) active!, ..._directCalls.values})
        call.close(),
    ];
    notifyListeners(); // Stop call audio before waiting for shutdown work.
    try {
      await Future.wait([
        ...mediaClosing,
        _push.endAll(),
        if (_events != null) _events!.cancel(),
        if (_lateEvents != null) _lateEvents!.cancel(),
        if (_callSignals != null) _callSignals!.cancel(),
        devices.close(),
      ]);
    } finally {
      audio.reset(null);
      screen?.dispose();
      _refresh();
      if (_backgroundUpdate != null) await _backgroundUpdate;
      if (_nativeCallActions) _nativeCalls.setMethodCallHandler(null);
      dispose();
    }
  }

  Future<void> acceptDirect(DirectCall call) async {
    if (active != null && !active!.isClosed) {
      throw UserActionError('Сначала завершите текущий звонок.');
    }
    if (!await _answerPush(call.session)) return;
    await beforeMedia?.call();
    active = call;
    directInvitations.remove(call);
    _refresh();
    try {
      await call.answer();
      if (!call.isClosed) devices.accept(call);
    } catch (_) {
      await call.close();
      rethrow;
    }
    directInvitations.remove(call);
    _refresh();
  }

  Future<void> declineDirect(DirectCall call) async {
    unawaited(
      _push
          .request('decline', call.session)
          .catchError((Object _) => <String, dynamic>{}),
    );
    _dismissInvitation(call.chat.id, call.session);
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
  ]) async {
    // shortcut: force TURN in loopback tests; real deployments use ICE's direct-first policy.
    if (const {
      'localhost',
      '127.0.0.1',
      '::1',
    }.contains(client.homeserver?.host)) {
      configuration = {...configuration, 'iceTransportPolicy': 'relay'};
    }
    await audio.startDirectAudio();
    try {
      return await rtc.createPeerConnection(configuration, constraints);
    } catch (_) {
      await audio.stopDirectAudio();
      rethrow;
    }
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
    _directCalls[session] = call;
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
    final call = _directCalls[session]!;
    if (_closed ||
        (session.direction == CallDirection.kOutgoing && !starting) ||
        (!canHandleNewCall && active != call) ||
        declined.contains((room: session.room.id, session: session.callId)) ||
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
    final current = active;
    if (current is DirectCall &&
        identical(current.call, session) &&
        session.direction == CallDirection.kOutgoing &&
        session.hangupReason == CallErrorCode.userBusy) {
      dialingRoom = session.room;
      dialError = 'Собеседник занят. Попробуйте позвонить ещё раз.';
    }
    if (active == null ||
        (current is DirectCall && identical(current.call, session))) {
      await audio.stopDirectAudio();
    }
    directInvitations.removeWhere((c) => identical(c.call, session));
    _refresh();
    final call = _directCalls[session];
    if (call != null) {
      // The SDK awaits this delegate while terminating. Neither media cleanup
      // nor a history write may hold up its hangup signalling.
      unawaited(call.close().catchError((Object _) {}));
      unawaited(_recordDirectEnd(call));
    }
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
