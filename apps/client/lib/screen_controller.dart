import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart' as mx;
import 'screen_api.dart';
import 'screen_binding.dart';
import 'screen_capture.dart';
import 'screen_state.dart';
import 'screen_key.dart';
import 'matrix_probe.dart';
import 'transport.dart';
import 'voice_call.dart';

/// Владеет только экраном текущего звонка; микрофон и камера остаются у VoiceCall.
class ScreenShareController extends ChangeNotifier {
  final VoiceCall call;
  final ScreenApi api;
  final String mediaUrl;
  final ScreenCallParties? parties;
  ScreenPhase phase = ScreenPhase.idle;
  ScreenSnapshot? snapshot;
  String? notice;
  lk.Room? media;
  lk.VideoTrack? remoteTrack;
  bool decoded = false;
  bool _closed = false, _polling = false, _acting = false;
  bool _bindingPending = false;
  bool _bindingInFlight = false;
  bool _preparingCapture = false;
  Completer<void>? _pollFinished;
  bool _disposed = false;
  String? _binding, _lease, _generation;
  int _serial = 0;
  Timer? _timer;
  ScreenCapture? _capture;
  lk.LocalVideoTrack? _publication;
  lk.BaseKeyProvider? _keys;
  Uint8List? _senderKey;
  lk.EventsListener<lk.RoomEvent>? _events;
  StreamSubscription<mx.ToDeviceEvent>? _messages;
  List<mx.DeviceKeys> _devices = [];
  final _authorized = Stopwatch();
  DateTime? _sharedAt;
  Future<void>? _closing;
  ({String action, Map<String, dynamic> body})? _pending;
  String get identity =>
      '${call.chat.client.userID}/${call.chat.client.deviceID}';
  bool get isClosed => _closed;
  bool get busy => _acting;
  lk.VideoTrack? get displayTrack => snapshot?.owner == identity
      ? media?.localParticipant?.videoTrackPublications.firstOrNull?.track
      : decoded
      ? remoteTrack
      : null;

  ScreenShareController(this.call, this.api, this.mediaUrl, {this.parties}) {
    secureEndpoint(mediaUrl, websocket: true);
  }

  void _changed() {
    if (!_closed && !_disposed) notifyListeners();
  }

  Future<void> connect() async {
    if (_closed || _binding != null || _bindingInFlight) return;
    _bindingInFlight = true;
    try {
      final result = await api.request(
        'bind',
        await screenBindingRequest(call, parties: parties),
      );
      if (_closed || call.isClosed) {
        await api.request('unbind', {
          'protocol_version': 1,
          'binding_id': result['binding_id'],
          'lease_id': result['lease_id'],
          'request_id': screenRequestId(),
        });
        return;
      }
      if (result['binding_id'] is! String ||
          result['lease_id'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(result['lease_id'])) {
        throw const FormatException('screen binding');
      }
      _binding = result['binding_id'];
      _lease = result['lease_id'];
      _bindingPending = result['binding_state'] == 'pending';
      _messages = call.chat.client.onToDeviceEvent.stream.listen((event) {
        unawaited(_receive(event).catchError((Object _) {}));
      });
      _authorized.start();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (call.isClosed ||
            _authorized.elapsed >= const Duration(seconds: 25)) {
          unawaited(close());
        } else {
          unawaited(poll());
        }
      });
      await _apply(result['snapshot'] as Map<String, dynamic>);
    } finally {
      _bindingInFlight = false;
      if (_closed) api.close();
    }
  }

  Future<void> poll() async {
    if (_closed || _polling || _acting || _binding == null) return;
    _polling = true;
    final finished = _pollFinished = Completer<void>();
    try {
      if (_pending != null) {
        final pending = _pending!;
        try {
          final result = await api.request(
            '$_binding/${pending.action}',
            pending.body,
          );
          if (result['status'] != 'pending') _pending = null;
        } on ScreenApiError catch (error) {
          if (error.status >= 500) rethrow;
          _pending = null;
          if (error.status != 409 && error.status != 429) rethrow;
        }
      }
      final result = _bindingPending
          ? await api.request('$_binding/state')
          : await api.request('$_binding/heartbeat', {
              'protocol_version': 1,
              'lease_id': _lease,
              'observed_revision': snapshot?.revision ?? 0,
              'capture_state': _capture == null ? 'idle' : 'sharing',
            });
      await _apply(
        _bindingPending ? result : result['snapshot'] as Map<String, dynamic>,
      );
      if (snapshot?.owner == identity && _capture == null && _pending == null) {
        await _command('stop');
      }
    } on ScreenApiError catch (error) {
      if ([401, 403, 404, 410].contains(error.status)) {
        await close();
      } else {
        phase = ScreenPhase.reconnecting;
        notice = 'Восстанавливаем демонстрацию.';
      }
    } on FormatException {
      notice = 'Демонстрация остановлена: неверный защищённый контекст.';
      await close();
    } catch (_) {
      phase = ScreenPhase.reconnecting;
    } finally {
      _polling = false;
      finished.complete();
      if (_pollFinished == finished) _pollFinished = null;
      _changed();
    }
  }

  Future<void> share() async {
    if (_closed ||
        _acting ||
        _pending != null ||
        snapshot == null ||
        _bindingPending ||
        _capture != null) {
      return;
    }
    _acting = true;
    _preparingCapture = true;
    final previousPhase = phase;
    phase = ScreenPhase.selecting;
    _changed();
    try {
      // Capture запускается до сетевых await, сохраняя browser user activation.
      final capture = await ScreenCapture.start();
      if (_closed || call.isClosed) {
        await capture.close();
        return;
      }
      await _capture?.close();
      _capture = capture;
      capture.source.mediaStreamTrack.onEnded = () {
        unawaited(stop());
      };
      await _pollFinished?.future;
      if (_closed || _capture != capture) {
        await capture.close();
        return;
      }
      _preparingCapture = false;
      phase = ScreenPhase.preparing;
      await _command('claim');
    } catch (_) {
      final captured = _capture;
      _capture = null;
      await captured?.close();
      if (captured != null) await _disposeMedia();
      notice = 'Показ не начат. Проверьте разрешение на захват экрана.';
      phase = captured == null ? previousPhase : ScreenPhase.error;
    } finally {
      _acting = false;
      _preparingCapture = false;
      _changed();
    }
  }

  Future<void> stop() async {
    if (_closed) return;
    final capture = _capture;
    _capture = null;
    await capture?.close();
    await _disposeMedia();
    if (_acting || _polling || _pending != null) return;
    _acting = true;
    try {
      if (snapshot?.owner == identity) await _command('stop');
    } catch (_) {
      notice = 'Показ остановлен локально; серверный статус уточняется.';
    } finally {
      _acting = false;
      _changed();
    }
  }

  Future<void> _command(String action) async {
    final body = {
      'protocol_version': 1,
      'lease_id': _lease,
      'request_id': screenRequestId(),
      'expected_revision': snapshot!.revision,
    };
    _pending = (action: action, body: body);
    try {
      final result = await api.request('$_binding/$action', body);
      if (result['status'] != 'pending') _pending = null;
      await _apply(result['snapshot'] as Map<String, dynamic>);
    } on ScreenApiError catch (error) {
      if (error.status < 500) _pending = null;
      rethrow;
    }
    // Неизвестный сетевой исход сохраняет тот же request_id для следующего poll.
  }

  Future<void> _apply(Map<String, dynamic> json) async {
    final next = ScreenSnapshot.parse(json);
    if (_closed ||
        next.binding != _binding ||
        (snapshot != null && next.revision < snapshot!.revision)) {
      return;
    }
    if (snapshot != null &&
        next.revision == snapshot!.revision &&
        (next.generation != snapshot!.generation ||
            next.owner != snapshot!.owner ||
            next.rosterVersion != snapshot!.rosterVersion)) {
      throw const FormatException('screen revision reuse');
    }
    final users = next.roster
        .map((d) => d.identity.substring(0, d.identity.lastIndexOf('/')))
        .toSet();
    final devices = next.roster.isEmpty
        ? <mx.DeviceKeys>[]
        : await authorizedDevices(call.chat, selectedUsers: users);
    if (_closed) return;
    for (final entry in next.roster) {
      if (!devices.any(
        (d) =>
            !d.blocked &&
            d.encryptToDevice &&
            '${d.userId}/${d.deviceId}' == entry.identity &&
            d.curve25519Key == entry.curve &&
            d.ed25519Key == entry.ed,
      )) {
        throw const FormatException('screen device trust');
      }
    }
    if (next.state == 'active' &&
        !next.roster.any((d) => d.identity == identity)) {
      throw const FormatException('screen own admission');
    }
    _devices = devices;
    snapshot = next;
    _authorized.reset();
    if (next.roster.any((d) => d.identity == identity)) _bindingPending = false;
    if (!_preparingCapture && next.owner != identity && _capture != null) {
      final capture = _capture;
      _capture = null;
      await capture!.close();
      notice = next.owner == null
          ? null
          : 'Другой участник перехватил демонстрацию.';
    }
    if (next.state == 'ended') {
      await close();
      return;
    }
    if (next.state != 'active') {
      await _disposeMedia();
      if (next.state == 'unavailable' &&
          next.owner == identity &&
          _capture != null &&
          _pending == null) {
        phase = ScreenPhase.preparing;
        await _command('claim');
        return;
      }
      phase = ScreenPhase.idle;
      _changed();
      return;
    }
    if (_generation != next.generation ||
        media?.connectionState == lk.ConnectionState.disconnected) {
      await _connectMedia(next);
    }
    await _shareKey();
    _changed();
  }

  bool _allowed(lk.RemoteTrackPublication publication, String sender) =>
      sender == snapshot?.owner &&
      publication.source == lk.TrackSource.screenShareVideo &&
      publication.encryptionType == lk.EncryptionType.kGcm &&
      !publication.mimeType.toLowerCase().contains('av1');

  Future<void> _connectMedia(ScreenSnapshot next) async {
    // Повторное подключение того же поколения сохраняет его sender key.
    final previousKey = _generation == next.generation
        ? _senderKey?.toList()
        : null;
    await _disposeMedia();
    if (_closed) return;
    final serial = _serial;
    _generation = next.generation;
    phase = ScreenPhase.connecting;
    decoded = false;
    final keys = await lk.BaseKeyProvider.create(
      sharedKey: false,
      discardFrameWhenCryptorNotReady: true,
    );
    if (_closed || serial != _serial) {
      await keys.keyProvider.dispose();
      return;
    }
    _keys = keys;
    if (next.owner == identity) {
      _senderKey = Uint8List.fromList(
        previousKey ?? List.generate(32, (_) => Random.secure().nextInt(256)),
      );
      await keys.setRawKey(_senderKey!, participantId: identity);
    }
    final room = lk.Room(
      roomOptions: lk.RoomOptions(
        encryption: lk.E2EEOptions(keyProvider: keys),
        // Renderer закрыт до kOk; adaptive stream иначе ждёт видимый renderer.
        adaptiveStream: false,
      ),
    );
    media = room;
    _events = room.createListener();
    void subscribe(String sender, lk.RemoteTrackPublication publication) {
      if (_closed || serial != _serial || !_allowed(publication, sender)) {
        return;
      }
      final videos =
          room.remoteParticipants[sender]?.videoTrackPublications ?? [];
      if (videos.length > 1) {
        unawaited(close());
        return;
      }
      unawaited(
        publication.subscribe().catchError((Object _) {
          unawaited(close());
        }),
      );
    }

    _events!.on<lk.TrackPublishedEvent>(
      (e) => subscribe(e.participant.identity, e.publication),
    );
    _events!.on<lk.TrackSubscribedEvent>((e) {
      if (serial != _serial ||
          !_allowed(e.publication, e.participant.identity) ||
          e.track is! lk.VideoTrack) {
        return;
      }
      remoteTrack = e.track as lk.VideoTrack;
      _changed();
    });
    _events!.on<lk.TrackE2EEStateEvent>((e) {
      if (serial != _serial ||
          e.participant.identity == identity ||
          e.participant.identity != snapshot?.owner) {
        return;
      }
      decoded = e.state == lk.E2EEState.kOk;
      phase = decoded ? ScreenPhase.viewing : ScreenPhase.connecting;
      _changed();
    });
    _events!.on<lk.RoomReconnectingEvent>((_) {
      if (serial != _serial) return;
      decoded = false;
      remoteTrack = null;
      phase = ScreenPhase.reconnecting;
      _changed();
    });
    _events!.on<lk.RoomDisconnectedEvent>((_) {
      if (serial != _serial || _closed) return;
      decoded = false;
      remoteTrack = null;
      phase = ScreenPhase.reconnecting;
      _changed();
    });
    final token = await api.request('$_binding/token', {
      'protocol_version': 1,
      'lease_id': _lease,
      'expected_revision': next.revision,
      'generation': next.generation,
    });
    if (_closed || serial != _serial) return;
    if (token['generation'] != next.generation ||
        token['revision'] != next.revision ||
        token['token'] is! String) {
      throw const FormatException('screen token context');
    }
    await room.connect(
      mediaUrl,
      token['token'],
      connectOptions: const lk.ConnectOptions(autoSubscribe: false),
    );
    if (_closed || serial != _serial) return;
    if (room.e2eeManager == null) {
      throw const FormatException('screen E2EE unavailable');
    }
    for (final participant in room.remoteParticipants.values) {
      for (final publication in participant.trackPublications.values) {
        subscribe(participant.identity, publication);
      }
    }
    if (next.owner == identity && _capture != null) {
      final publication = await _capture!.publication();
      if (_closed || serial != _serial) {
        await publication.dispose();
        return;
      }
      try {
        _publication = publication;
        await room.localParticipant!.publishVideoTrack(publication);
      } catch (_) {
        await publication.dispose();
        rethrow;
      }
      phase = ScreenPhase.sharing;
    }
    await _shareKey(force: true);
  }

  Future<void> _shareKey({bool force = false}) async {
    final current = snapshot;
    if (_closed ||
        current == null ||
        current.owner != identity ||
        _senderKey == null ||
        _generation != current.generation) {
      return;
    }
    if (!force &&
        _sharedAt != null &&
        DateTime.now().difference(_sharedAt!) < const Duration(seconds: 8)) {
      return;
    }
    final recipients = _devices
        .where(
          (d) =>
              '${d.userId}/${d.deviceId}' != identity &&
              current.roster.any(
                (r) => r.identity == '${d.userId}/${d.deviceId}',
              ),
        )
        .toList();
    await call.chat.client
        .sendToDeviceEncrypted(recipients, 'dev.voicechat.screen_key.v1', {
          'protocol_version': 1,
          'room_id': call.chat.id,
          'call_session': call.session,
          'binding_id': _binding,
          'screen_generation': _generation,
          'revision': current.revision,
          'roster_version': current.rosterVersion,
          'sender_identity': identity,
          'sender_device': call.chat.client.deviceID,
          'expires_at': DateTime.now()
              .add(const Duration(seconds: 20))
              .millisecondsSinceEpoch,
          'key': base64Encode(_senderKey!),
        });
    _sharedAt = DateTime.now();
  }

  Future<void> _receive(mx.ToDeviceEvent event) async {
    final current = snapshot, keys = _keys;
    if (_closed ||
        current == null ||
        keys == null ||
        _authorized.elapsed >= const Duration(seconds: 25) ||
        event.type != 'dev.voicechat.screen_key.v1' ||
        event.encryptedContent == null) {
      return;
    }
    final curve = event.encryptedContent!['sender_key'];
    if (curve is! String) return;
    final device = call.chat.client.getUserDeviceKeysByCurve25519Key(curve);
    if (device == null ||
        device.blocked ||
        !device.encryptToDevice ||
        device.userId != event.sender ||
        device.deviceId == null ||
        '${device.userId}/${device.deviceId}' != current.owner ||
        !_devices.any(
          (d) =>
              d.userId == device.userId &&
              d.deviceId == device.deviceId &&
              d.ed25519Key == device.ed25519Key &&
              d.curve25519Key == device.curve25519Key,
        )) {
      return;
    }
    final key = screenKey(
      event.content,
      snapshot: current,
      room: call.chat.id,
      session: call.session,
      sender: device.userId,
      device: device.deviceId!,
      curve: device.curve25519Key!,
      ed: device.ed25519Key!,
      now: DateTime.now().millisecondsSinceEpoch,
    );
    if (key == null || _closed || keys != _keys) return;
    await keys.setRawKey(
      Uint8List.fromList(key),
      participantId: current.owner!,
    );
  }

  Future<void> _disposeMedia() async {
    _serial++;
    _generation = null;
    _senderKey?.fillRange(0, _senderKey!.length, 0);
    _senderKey = null;
    _sharedAt = null;
    remoteTrack = null;
    decoded = false;
    final events = _events, room = media, keys = _keys;
    final publication = _publication;
    _publication = null;
    _events = null;
    media = null;
    _keys = null;
    try {
      // Web clone тоже держит capture: прекращаем его до любых сетевых await.
      await publication?.dispose();
      await events?.dispose();
    } finally {
      try {
        if (room != null &&
            room.connectionState != lk.ConnectionState.disconnected) {
          await room.disconnect();
        }
        await room?.dispose();
      } finally {
        await keys?.keyProvider.dispose();
      }
    }
  }

  Future<void> close() => _closing ??= _close().catchError((Object _) {});
  Future<void> _close() async {
    _closed = true;
    _timer?.cancel();
    phase = ScreenPhase.closed;
    if (!_disposed) notifyListeners();
    final capture = _capture;
    _capture = null;
    try {
      await capture?.close();
    } finally {
      try {
        await _messages?.cancel();
        await _disposeMedia();
      } finally {
        try {
          if (_binding != null) {
            await api.request('unbind', {
              'protocol_version': 1,
              'binding_id': _binding,
              'lease_id': _lease,
              'request_id': screenRequestId(),
            });
          }
        } catch (_) {
          /* Lease завершится на сервере без доверия к клиентской очистке. */
        }
        if (!_bindingInFlight) api.close();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}
