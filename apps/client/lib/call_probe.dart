import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart' as mx;
import 'matrix_probe.dart';
import 'transport.dart';
import 'route_transport.dart';
import 'media_routes.dart';
import 'voice_call.dart';
import 'call_quality.dart';
import 'user_action_error.dart';

class CallFull extends UserActionError {
  CallFull()
    : super('В звонке уже десять участников. Дождитесь свободного места.');
}

bool allowsCallMedia(
  lk.EncryptionType encryption,
  lk.TrackSource source,
  String mime, {
  required bool video,
}) =>
    encryption == lk.EncryptionType.kGcm &&
    !mime.toLowerCase().contains('av1') &&
    (source == lk.TrackSource.microphone ||
        video && source == lk.TrackSource.camera);

/// Sender-specific keys are bound to a server lease and media generation.
class CallProbe implements VoiceCall {
  @override
  final mx.Room chat;
  @override
  final String session;
  final String tokenUrl;
  final String livekitUrl;
  late final http.Client _network = chat.client.httpClient is RouteTransport
      ? (chat.client.httpClient as RouteTransport).fork()
      : http.Client();
  final void Function(String) status;
  final void Function()? changed;
  final bool startedWithVideo;
  @override
  bool get video =>
      startedWithVideo ||
      cameraEnabled ||
      (media?.remoteParticipants.values.any(
            (p) => p.videoTrackPublications.any((t) => !t.muted),
          ) ??
          false);
  @override
  VideoQuality videoQuality = VideoQuality.auto;
  @override
  bool cameraEnabled = false;
  @override
  CallQuality get quality =>
      switch (media?.localParticipant?.connectionQuality) {
        lk.ConnectionQuality.excellent => CallQuality.excellent,
        lk.ConnectionQuality.good => CallQuality.good,
        lk.ConnectionQuality.poor => CallQuality.poor,
        lk.ConnectionQuality.lost => CallQuality.lost,
        _ => CallQuality.unknown,
      };
  lk.CameraPosition _cameraPosition = lk.CameraPosition.front;
  final Set<String> decryptedVideoFrom = {};
  final Set<String> decryptedVideoTracks = {};
  Set<String> _allowedParticipants = {};
  @override
  String connection = 'Подключение';
  @override
  bool muted = false;
  @override
  List<String> get participants => [
    identity,
    ...?media?.remoteParticipants.keys,
  ];
  lk.Room? media;
  lk.BaseKeyProvider? _keys;
  StreamSubscription<mx.ToDeviceEvent>? _messages;
  lk.EventsListener<lk.RoomEvent>? _events;
  Timer? _resend;
  Uint8List _senderKey = Uint8List.fromList(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  );
  final Set<String> decryptedAudioFrom = {};
  final Set<String> failedAudioFrom = {};
  Set<String>? _authorization;
  Set<String> _keyRecipients = {};
  DateTime? _keySharedAt;
  @override
  bool get isClosed => _closed;
  Future<void>? _sharing;
  int _transportSerial = 0, _sharingSerial = 0;
  bool _closed = false;
  Future<void>? _closing;
  DateTime _authorizedAt = DateTime.now();
  Map<String, dynamic>? _admission;

  /// Только собственный допуск активного группового звонка, не отдельное место SFU.
  String? get screenBindingLease => _admission?['lease_id'] as String?;
  List<mx.DeviceKeys> _devices = [];
  Future<void>? _renewing;
  bool _rebuilding = false;
  bool _microphone = true;
  bool _wantedCamera = false;
  final _clock = Stopwatch();
  @override
  Duration get duration => _clock.elapsed;

  String get identity => '${chat.client.userID}/${chat.client.deviceID}';
  CallProbe({
    required this.chat,
    required this.session,
    required this.tokenUrl,
    required this.livekitUrl,
    required this.status,
    this.changed,
    bool video = false,
  }) : startedWithVideo = video;

  Future<void> connect({bool microphone = true}) async {
    _microphone = microphone;
    _wantedCamera = startedWithVideo;
    _rebuilding = true;
    try {
      await _connect(microphone: microphone, camera: startedWithVideo);
    } catch (error, stack) {
      try {
        await close();
      } catch (_) {
        status('Ресурсы звонка закрыты с ошибкой');
      }
      Error.throwWithStackTrace(error, stack);
    } finally {
      _rebuilding = false;
    }
  }

  Future<void> _connect({
    required bool microphone,
    required bool camera,
  }) async {
    final budget = Stopwatch()..start();
    while (!_closed) {
      try {
        await _connectTransport(microphone: microphone, camera: camera);
        return;
      } catch (error, stack) {
        if (mediaNetworkFailure(error) &&
            budget.elapsed < const Duration(seconds: 45) &&
            !_closed) {
          connection = 'Обновляем защиту звонка';
          changed?.call();
          final generation = _admission?['generation'] as String?;
          await _disposeTransport();
          _admission = await _requestAdmission(reconnect: generation);
          _newKeys();
          continue;
        }
        try {
          await close();
        } catch (_) {
          status('Ресурсы звонка закрыты с ошибкой');
        }
        Error.throwWithStackTrace(error, stack);
      }
    }
  }

  Future<void> _connectTransport({
    required bool microphone,
    required bool camera,
  }) async {
    if (!chat.encrypted) {
      throw StateError('Call requires an encrypted Matrix room');
    }
    secureEndpoint(tokenUrl);
    secureEndpoint(livekitUrl, websocket: true);
    connection = 'Готовим защиту звонка';
    status(connection);
    changed?.call();
    final keys = await lk.BaseKeyProvider.create(
      sharedKey: false,
      discardFrameWhenCryptorNotReady: true,
    );
    if (_closed) {
      await keys.keyProvider.dispose();
      throw StateError('Call closed during key provider creation');
    }
    _keys = keys;
    await _keys!.setRawKey(_senderKey, participantId: identity);
    _messages = chat.client.onToDeviceEvent.stream.listen((event) {
      unawaited(
        _receive(event).catchError((Object _) {
          status('Ключ участника отклонён');
        }),
      );
    });
    final transportSerial = _transportSerial;
    media = routedMediaRoom(
      chat.client,
      livekitUrl,
      lk.RoomOptions(
        encryption: lk.E2EEOptions(keyProvider: _keys!),
        adaptiveStream: true,
        dynacast: true,
      ),
      canRecover: () => !_closed && transportSerial == _transportSerial,
    );
    _events = media!.createListener();
    _events!.on<lk.LocalTrackPublishedEvent>((_) => changed?.call());
    _events!.on<lk.ParticipantConnectedEvent>((_) => changed?.call());
    _events!.on<lk.ParticipantDisconnectedEvent>((_) => changed?.call());
    _events!.on<lk.ParticipantConnectionQualityUpdatedEvent>(
      (_) => changed?.call(),
    );
    _events!.on<lk.TrackSubscribedEvent>((event) {
      if (!allowsCallMedia(
        event.publication.encryptionType,
        event.publication.source,
        event.publication.mimeType,
        video: true,
      )) {
        unawaited(close());
        status('Поток без поддерживаемой E2EE-защиты отклонён');
      } else {
        changed?.call();
      }
    });
    _events!.on<lk.TrackPublishedEvent>(
      (event) => _subscribe(event.participant.identity, event.publication),
    );
    _events!.on<lk.TrackUnsubscribedEvent>((event) {
      decryptedVideoTracks.remove(event.publication.sid);
      changed?.call();
    });
    _events!.on<lk.TrackMutedEvent>((_) => changed?.call());
    _events!.on<lk.TrackUnmutedEvent>((_) => changed?.call());
    _events!.on<lk.RoomReconnectingEvent>((_) {
      connection = 'Восстанавливаем соединение';
      status(connection);
      changed?.call();
    });
    _events!.on<lk.RoomReconnectedEvent>((_) {
      connection = 'Соединение восстановлено';
      status(connection);
      changed?.call();
      if (!_closed) unawaited(_renew());
    });
    _events!.on<lk.RoomDisconnectedEvent>((_) {
      connection = 'Восстанавливаем соединение';
      changed?.call();
      if (!_closed && !_rebuilding) unawaited(_renew());
    });
    _events!.on<lk.TrackE2EEStateEvent>((event) {
      if (event.participant.identity == identity) return;
      if (event.state == lk.E2EEState.kOk) {
        _clock.start();
        if (event.publication.kind == lk.TrackType.VIDEO) {
          decryptedVideoFrom.add(event.participant.identity);
          decryptedVideoTracks.add(event.publication.sid);
        } else {
          decryptedAudioFrom.add(event.participant.identity);
        }
        connection = video ? 'Защищённое видео' : 'Защищённое аудио';
        status('Получено E2EE-аудио: ${decryptedAudioFrom.length}');
        changed?.call();
      } else if (event.state == lk.E2EEState.kDecryptionFailed ||
          event.state == lk.E2EEState.kMissingKey) {
        decryptedVideoTracks.remove(event.publication.sid);
        failedAudioFrom.add(event.participant.identity);
        status('Ожидаем правильный ключ участника');
      }
    });
    connection = 'Проверяем доступ к звонку';
    status(connection);
    changed?.call();
    _admission ??= await _requestAdmission();
    await shareKey().timeout(const Duration(seconds: 8));
    _validateRoster();
    final data = _admission!;
    connection = 'Подключаем медиа';
    status(connection);
    changed?.call();
    final connectOptions = await routedMediaOptions(chat.client);
    if (_closed) return;
    await media!.connect(
      _network is RouteTransport
          ? _network.websocketUrl(livekitUrl)
          : livekitUrl,
      data['token'] as String,
      connectOptions: connectOptions,
    );
    if (media!.e2eeManager == null) {
      throw StateError('E2EE unavailable; refusing microphone');
    }
    await shareKey().timeout(const Duration(seconds: 15));
    _resend ??= Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_renew()),
    );
    if (_closed) throw StateError('Call closed during authorization');
    connection = 'Включаем медиа';
    status(connection);
    changed?.call();
    if (microphone) await media!.localParticipant!.setMicrophoneEnabled(true);
    if (camera && (startedWithVideo || data['camera_allowed'] == true)) {
      await this.camera(true);
    } else if (camera) {
      _wantedCamera = false;
      status('Камера выключена: участнику требуется обновление приложения.');
    }
    connection = 'E2EE включено · ждём медиапотоки';
    status(connection);
    changed?.call();
  }

  Future<Map<String, dynamic>> _requestAdmission({String? reconnect}) async {
    final budget = Stopwatch()..start();
    while (!_closed) {
      if (budget.elapsed >= const Duration(seconds: 25)) {
        throw TimeoutException('Call admission negotiation timed out');
      }
      final response = await _network
          .post(
            Uri.parse('$tokenUrl/token'),
            headers: {
              'Authorization': 'Bearer ${chat.client.accessToken}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'room_id': chat.id,
              'session': session,
              'video': startedWithVideo,
              'camera_capable': true,
              'protocol_version': 1,
              if (_admission != null) 'lease_id': _admission!['lease_id'],
              if (reconnect != null) 'reconnect': reconnect,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.bodyBytes.length > 32768) {
        throw const FormatException('Invalid admission size');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 410) {
        _admission = null;
        reconnect = null;
        continue;
      }
      if (response.statusCode == 409 &&
          data['error'] == 'generation_settling' &&
          budget.elapsed < const Duration(seconds: 20)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        continue;
      }
      if (response.statusCode == 409 && data['error'] == 'call_full') {
        throw CallFull();
      }
      if ([401, 403].contains(response.statusCode)) throw CallAccessChanged();
      if (response.statusCode != 200) {
        throw http.ClientException('Call admission unavailable');
      }
      if (data['identity'] != identity ||
          data['lease_seconds'] != 30 ||
          data['generation'] is! String ||
          !RegExp(r'^vc-[a-f0-9]{48}$').hasMatch(data['generation']) ||
          data['lease_id'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(data['lease_id']) ||
          data['token'] is! String ||
          data['roster'] is! List ||
          (data['roster'] as List).isEmpty ||
          (data['roster'] as List).length > 10) {
        throw const FormatException('Invalid call admission');
      }
      _authorizedAt = DateTime.now();
      return data;
    }
    throw StateError('Call closed during admission');
  }

  void _validateRoster() {
    final roster = (_admission!['roster'] as List);
    final identities = <String>{};
    for (final entry in roster) {
      if (entry is! Map ||
          entry['identity'] is! String ||
          !identities.add(entry['identity']) ||
          !_devices.any(
            (d) =>
                '${d.userId}/${d.deviceId}' == entry['identity'] &&
                d.encryptToDevice &&
                !d.blocked &&
                d.curve25519Key == entry['curve'] &&
                d.ed25519Key == entry['ed'],
          )) {
        throw CallAccessChanged();
      }
    }
    if (!identities.contains(identity)) throw CallAccessChanged();
    _allowedParticipants = identities;
  }

  Future<void> _renew() =>
      _renewing ??= _renewLease().whenComplete(() => _renewing = null);

  Future<void> _renewLease() async {
    if (_closed || _rebuilding) return;
    try {
      final next = await _requestAdmission();
      if (_closed) return;
      final changedGeneration = next['generation'] != _admission?['generation'];
      final disconnected =
          media == null ||
          media?.connectionState == lk.ConnectionState.disconnected;
      if (changedGeneration || disconnected) {
        _rebuilding = true;
        final camera = _wantedCamera;
        _clock.stop();
        final old = _admission?['generation'] as String?;
        await _disposeTransport();
        _admission = disconnected && !changedGeneration
            ? await _requestAdmission(reconnect: old)
            : next;
        _newKeys();
        await _connect(microphone: _microphone && !muted, camera: camera);
      } else {
        _admission = next;
        _validateRoster();
        await shareKey(force: false).timeout(const Duration(seconds: 10));
      }
    } catch (error) {
      if (_closed) return;
      if (callAccessDenied(error) ||
          DateTime.now().difference(_authorizedAt) >=
              const Duration(seconds: 25)) {
        await close();
        status('Звонок завершён: доступ отозван или не удалось его проверить');
      } else {
        connection = 'Восстанавливаем соединение';
        changed?.call();
      }
    } finally {
      _rebuilding = false;
    }
  }

  void _newKeys() {
    _authorization = null;
    _devices = [];
    _keyRecipients = {};
    _keySharedAt = null;
    decryptedAudioFrom.clear();
    decryptedVideoFrom.clear();
    decryptedVideoTracks.clear();
    _senderKey = Uint8List.fromList(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    );
  }

  void _subscribe(String identity, lk.RemoteTrackPublication publication) {
    if (_closed || !_allowedParticipants.contains(identity)) return;
    if (!allowsCallMedia(
      publication.encryptionType,
      publication.source,
      publication.mimeType,
      video: true,
    )) {
      unawaited(close());
      status('Поток без поддерживаемой E2EE-защиты отклонён');
      return;
    }
    unawaited(
      publication.subscribe().catchError((Object _) async {
        await close();
        status('Не удалось безопасно подключить медиапоток');
      }),
    );
  }

  void _subscribeAvailable() {
    if (media?.connectionState != lk.ConnectionState.connected) return;
    for (final entry in media!.remoteParticipants.entries) {
      for (final publication in entry.value.trackPublications.values) {
        if (!publication.subscribed) _subscribe(entry.key, publication);
      }
    }
  }

  Future<void> shareKey({bool force = true}) {
    if (_closed) return Future.value();
    if (_sharing != null && _sharingSerial == _transportSerial) {
      return _sharing!;
    }
    final serial = _sharingSerial = _transportSerial;
    return _sharing = _shareKey(force, serial).whenComplete(() {
      if (_transportSerial == serial) _sharing = null;
    });
  }

  Future<void> _shareKey(bool force, int serial) async {
    final authorized = _admission == null || _devices.isEmpty
        ? await authorizedDevices(
            chat,
            selectedUsers: _admission == null
                ? null
                : (_admission!['roster'] as List).map((entry) {
                    if (entry is! Map || entry['identity'] is! String) {
                      throw const FormatException('Invalid roster');
                    }
                    final value = entry['identity'] as String;
                    final separator = value.lastIndexOf('/');
                    if (separator < 1) {
                      throw const FormatException('Invalid identity');
                    }
                    return value.substring(0, separator);
                  }).toSet(),
          )
        : _devices;
    if (_closed || serial != _transportSerial) return;
    _devices = authorized;
    final current = authorized
        .map(
          (d) => '${d.userId}/${d.deviceId}/${d.curve25519Key}/${d.ed25519Key}',
        )
        .toSet();
    if (_authorization != null &&
        (_authorization!.length != current.length ||
            !_authorization!.containsAll(current))) {
      // shortcut: end the call; replace with coordinated epochs before seamless rekey.
      throw CallAccessChanged();
    }
    _authorization = current;
    _allowedParticipants = authorized
        .map((d) => '${d.userId}/${d.deviceId}')
        .toSet();
    if (_admission != null) _validateRoster();
    // Full SDK reconnect rebuilds publications without TrackPublished events.
    _subscribeAvailable();
    final devices = authorized
        .where(
          (d) => _admission == null
              ? media!.remoteParticipants.containsKey(
                  '${d.userId}/${d.deviceId}',
                )
              : '${d.userId}/${d.deviceId}' != identity &&
                    _allowedParticipants.contains('${d.userId}/${d.deviceId}'),
        )
        .toList();
    final recipients = devices.map((d) => '${d.userId}/${d.deviceId}').toSet();
    // Keep access checks frequent without re-encrypting identical keys every poll.
    if (!force &&
        _keySharedAt != null &&
        DateTime.now().difference(_keySharedAt!) < const Duration(seconds: 9) &&
        recipients.length == _keyRecipients.length &&
        recipients.containsAll(_keyRecipients)) {
      return;
    }
    await chat.client
        .sendToDeviceEncrypted(devices, 'dev.voicechat.probe.media_key', {
          'room_id': chat.id,
          'session': session,
          if (_admission != null) 'generation': _admission!['generation'],
          'identity': identity,
          'sender_device': chat.client.deviceID,
          'expires_at': DateTime.now()
              .add(const Duration(seconds: 20))
              .millisecondsSinceEpoch,
          'key': base64Encode(_senderKey),
        });
    if (serial == _transportSerial) {
      _keyRecipients = recipients;
      _keySharedAt = DateTime.now();
    }
  }

  Future<void> _receive(mx.ToDeviceEvent event) async {
    if (_closed ||
        event.type != 'dev.voicechat.probe.media_key' ||
        event.encryptedContent == null) {
      return;
    }
    final data = event.content;
    if (data['room_id'] != chat.id ||
        data['session'] != session ||
        _admission == null ||
        data['generation'] != _admission!['generation']) {
      return;
    }
    if (!_allowedParticipants.contains(data['identity'])) {
      return;
    }
    final expires = data['expires_at'];
    if (expires is! int ||
        expires < DateTime.now().millisecondsSinceEpoch ||
        expires >
            DateTime.now()
                .add(const Duration(minutes: 1))
                .millisecondsSinceEpoch) {
      return;
    }
    final senderKey = event.encryptedContent!['sender_key'];
    if (senderKey is! String) return;
    final device = chat.client.getUserDeviceKeysByCurve25519Key(senderKey);
    if (device == null ||
        device.blocked ||
        !device.encryptToDevice ||
        device.userId != event.sender ||
        device.deviceId != data['sender_device'] ||
        data['identity'] != '${device.userId}/${device.deviceId}') {
      return;
    }
    if (!_devices.any(
      (d) =>
          d.userId == device.userId &&
          d.deviceId == device.deviceId &&
          d.ed25519Key == device.ed25519Key &&
          d.curve25519Key == device.curve25519Key,
    )) {
      return;
    }
    if (_closed ||
        DateTime.now().difference(_authorizedAt) >=
            const Duration(seconds: 25)) {
      return;
    }
    final key = base64Decode(data['key'] as String);
    if (key.length != 32) return;
    await _keys!.setRawKey(key, participantId: data['identity'] as String);
  }

  @override
  Future<void> mute(bool value) async {
    await media?.localParticipant?.setMicrophoneEnabled(!value);
    muted = value;
    changed?.call();
  }

  lk.CameraCaptureOptions get _cameraOptions => lk.CameraCaptureOptions(
    cameraPosition: _cameraPosition,
    maxFrameRate: videoQuality.fps.toDouble(),
    params: lk.VideoParameters(
      dimensions: lk.VideoDimensions(videoQuality.width, videoQuality.height),
      encoding: lk.VideoEncoding(
        maxBitrate: videoQuality.bitrate,
        maxFramerate: videoQuality.fps,
      ),
    ),
  );

  @override
  Future<void> camera(bool enabled) async {
    if (_closed || enabled == cameraEnabled) return;
    if (enabled && !_rebuilding) await _renew();
    if (_closed) return;
    if (enabled && !startedWithVideo && _admission?['camera_allowed'] != true) {
      throw UserActionError(
        'Для включения камеры все участники аудиозвонка должны обновить приложение.',
      );
    }
    final participant = media!.localParticipant!;
    if (enabled) {
      final track = await lk.LocalVideoTrack.createCameraTrack(_cameraOptions);
      try {
        if (_closed) throw StateError('Call ended during camera permission');
        await participant.publishVideoTrack(
          track,
          publishOptions: lk.VideoPublishOptions(
            videoEncoding: _cameraOptions.params.encoding,
            simulcast: videoQuality == VideoQuality.auto,
          ),
        );
      } catch (_) {
        await track.stop();
        await track.dispose();
        rethrow;
      }
    } else {
      for (final publication in participant.videoTrackPublications.toList()) {
        await participant.removePublishedTrack(publication.sid);
      }
    }
    cameraEnabled = enabled;
    _wantedCamera = enabled;
    changed?.call();
  }

  @override
  Future<void> switchCamera() async {
    if (!cameraEnabled || _closed) return;
    final next = _cameraPosition == lk.CameraPosition.front
        ? lk.CameraPosition.back
        : lk.CameraPosition.front;
    final track = media!.localParticipant!.videoTrackPublications.first.track;
    if (track is! lk.LocalVideoTrack) return;
    await track.setCameraPosition(next);
    _cameraPosition = next;
    changed?.call();
  }

  @override
  Future<void> setVideoQuality(VideoQuality value) async {
    if (_closed || !video || value == videoQuality) return;
    final enabled = cameraEnabled;
    if (enabled) await camera(false);
    videoQuality = value;
    if (enabled) await camera(true);
    changed?.call();
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _clock.stop();
    cameraEnabled = false;
    _resend?.cancel();
    try {
      await _disposeTransport();
    } finally {
      final lease = _admission?['lease_id'];
      _admission = null;
      if (lease != null) {
        try {
          await _network
              .post(
                Uri.parse('$tokenUrl/call/leave'),
                headers: {
                  'Authorization': 'Bearer ${chat.client.accessToken}',
                  'Content-Type': 'application/json',
                },
                body: jsonEncode({'lease_id': lease}),
              )
              .timeout(const Duration(seconds: 5));
        } catch (_) {
          /* The server expires the lease even if release cannot be delivered. */
        }
      }
      _network.close();
    }
  }

  Future<void> _disposeTransport() async {
    _transportSerial++;
    _clock.stop();
    cameraEnabled = false;
    try {
      await Future.wait([
        _messages?.cancel() ?? Future.value(),
        _events?.dispose() ?? Future.value(),
      ]);
    } finally {
      try {
        // A never-connected SDK room cannot emit the disconnect acknowledgement it waits for.
        if (media?.connectionState != lk.ConnectionState.disconnected) {
          await media?.disconnect();
        }
      } finally {
        try {
          await media?.dispose();
        } finally {
          try {
            // The provider belongs to this call; Room disposes cryptors, not the provider.
            await _keys?.keyProvider.dispose();
          } finally {
            _keys = null;
            _senderKey.fillRange(0, _senderKey.length, 0);
            media = null;
            _messages = null;
            _events = null;
            connection = _closed
                ? 'Звонок завершён'
                : 'Обновляем защиту звонка';
            changed?.call();
          }
        }
      }
    }
  }
}
