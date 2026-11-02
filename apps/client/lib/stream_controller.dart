import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'stream_wake.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:vodozemac/vodozemac.dart' as vod;
import 'active_capture.dart';
import 'call_audio_platform.dart';
import 'call_quality.dart';
import 'camera_capture.dart';
import 'call_probe.dart' show allowsCallMedia;
import 'package:http/http.dart' as http;
import 'media_routes.dart';
import 'route_transport.dart';
import 'screen_api.dart' show screenRequestId;
import 'stream_api.dart';
import 'stream_crypto.dart';
import 'stream_state.dart';
import 'user_action_error.dart';

class LiveStreamComment {
  final int sequence;
  final String author, text;
  const LiveStreamComment(this.sequence, this.author, this.text);
}

/// A single foreground stream, independent of Matrix room/call history.
class LiveStreamController extends ChangeNotifier with WidgetsBindingObserver {
  final _wake = StreamWakeLock();
  bool _background = false, _pauseRequested = false, _changingVideo = false;
  bool get paused => _pauseRequested || snapshot?.state == 'paused';
  final mx.Client client;
  final String mediaUrl;
  final LiveStreamApi api;
  final bool Function() callActive;
  Future<void>? _closing;
  LiveStreamSnapshot? snapshot;
  LiveStreamCrypto? _crypto;
  final comments = <LiveStreamComment>[];
  lk.Room? media;
  lk.EventsListener<lk.RoomEvent>? _events;
  lk.BaseKeyProvider? _keys;
  Timer? _timer, _directoryTimer;
  bool available = false;
  int maxDuration = 10800;
  List<LiveStreamSnapshot> directory = [];
  bool _discovering = false;
  Future<void> _queue = Future.value();
  bool _polling = false, _closed = false;
  bool cameraOn = true,
      microphoneOn = true,
      speakerOn = true,
      backCamera = false;
  bool connecting = false;
  VideoQuality quality = VideoQuality.auto;
  String status = '';
  String? _generation;
  final _outgoing = <String, List<Map<String, dynamic>>>{};
  final _uploaded = <String>{};
  int _sharedEpoch = 0, _historySequence = 0;
  final decryptedVideo = <String>{};
  Stopwatch elapsed = Stopwatch();
  bool get owner =>
      snapshot != null &&
      snapshot?.owner == client.userID &&
      snapshot?.ownerDevice == client.deviceID;
  bool get active => snapshot != null;
  LiveStreamController(
    this.client,
    String base,
    this.mediaUrl, {
    bool Function()? callActive,
    http.Client? httpClient,
  }) : callActive = callActive ?? (() => false),
       api = LiveStreamApi(
         base,
         () => client.accessToken ?? '',
         client:
             httpClient ??
             routeTransportOf(client.httpClient)?.fork() ??
             http.Client(),
       ) {
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> open() async {
    try {
      final value = await api.capabilities();
      available = value['enabled'] == true && value['media_enabled'] == true;
      if (value['max_duration'] is int && value['max_duration'] > 0) {
        maxDuration = value['max_duration'] as int;
      }
    } catch (_) {
      available = false;
    }
    if (_closed) return;
    if (available) {
      await discover();
      _directoryTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(discover()),
      );
    }
    changed();
  }

  Future<void> discover() async {
    if (_discovering || _closed || !available) return;
    _discovering = true;
    try {
      final value = await api.command('discover');
      final entries = value['streams'];
      if (entries is! List || entries.length > 100) {
        throw const FormatException('stream list');
      }
      final parsed = entries
          .map(
            (v) =>
                LiveStreamSnapshot.parse(Map<String, dynamic>.from(v as Map)),
          )
          .toList();
      if (!_closed) {
        directory = parsed;
        changed();
      }
    } catch (_) {
      if (!_closed) {
        directory = [];
        changed();
      }
    } finally {
      _discovering = false;
    }
  }

  Future<T> serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void changed() {
    if (!_closed) notifyListeners();
  }

  void adopt(Map<String, dynamic> value) {
    snapshot = LiveStreamSnapshot.parse(value);
    elapsed = Stopwatch()..start();
    _crypto ??= LiveStreamCrypto(
      snapshot!.id,
      snapshot!.endsAt.millisecondsSinceEpoch,
    );
    changed();
  }

  Future<void> start(Map<String, dynamic> settings) => serial(() async {
    if (_closed || active) {
      throw UserActionError('Сначала выйдите из текущего эфира.');
    }
    if (callActive()) {
      throw UserActionError('Сначала завершите текущий звонок.');
    }
    if (hasActiveCapture) {
      throw UserActionError('Сначала завершите текущую запись.');
    }
    final capabilities = await api.capabilities();
    if (capabilities['media_enabled'] != true) {
      throw UserActionError('Стримы пока недоступны.');
    }
    adopt(
      await api.command('start', {
        'request_id': screenRequestId(),
        ...settings,
      }),
    );
    schedule();
    try {
      await refresh();
    } catch (_) {
      await leaveInternal();
      rethrow;
    }
  });

  Future<void> join(String identifier) => serial(() async {
    if (_closed || active) {
      throw UserActionError('Сначала выйдите из текущего эфира.');
    }
    if (callActive()) {
      throw UserActionError('Сначала завершите текущий звонок.');
    }
    adopt(await api.command('join', {'stream_id': identifier}));
    schedule();
    try {
      await refresh();
    } on LiveStreamError catch (error) {
      if (error.code != 'stream_key_pending') rethrow;
      status = 'Ожидаем защищённое подключение';
      changed();
    }
  });

  void schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_polling || _closed || !active) return;
      _polling = true;
      unawaited(
        serial(() async {
          try {
            await refresh();
          } on LiveStreamError catch (error) {
            if ({401, 403, 404}.contains(error.status)) {
              await leaveInternal(notifyServer: false);
              status = 'Эфир завершён или доступ отозван';
            } else {
              status = 'Восстанавливаем соединение';
            }
          } on FormatException {
            await leaveInternal();
            status = 'Не удалось безопасно продолжить эфир';
          } catch (_) {
            status = 'Проверяем соединение';
          } finally {
            if (snapshot != null &&
                elapsed.elapsed >= const Duration(seconds: 25)) {
              await disconnectMedia();
            }
            if (snapshot?.remaining(elapsed.elapsed) == Duration.zero) {
              await leaveInternal(notifyServer: false);
            }
            _polling = false;
            changed();
          }
        }),
      );
    });
  }

  Future<void> refresh() async {
    var current = snapshot;
    if (current == null || _closed) return;
    if (current.remaining(elapsed.elapsed) == Duration.zero) {
      await leaveInternal(notifyServer: false);
      status = 'Эфир завершён';
      return;
    }
    if (owner && _pauseRequested && current.state != 'paused') {
      await disconnectMedia();
      adopt(
        await api.command('pause', {
          'stream_id': current.id,
          'revision': current.revision,
        }),
      );
      current = snapshot!;
    }
    adopt(
      await api.command('heartbeat', {
        'stream_id': current.id,
        'ready':
            current.state == 'paused' ||
            (!_pauseRequested &&
                !_background &&
                media?.connectionState == lk.ConnectionState.connected),
      }),
    );
    current = snapshot!;
    if (_closed) return;
    if (owner) {
      await shareKeys(current);
    } else {
      await receiveKeys(current);
    }
    if (_closed || snapshot == null) return;
    if (_background && owner && current.state != 'paused') {
      await disconnectMedia();
      return;
    }
    if (current.state == 'paused') {
      await disconnectMedia();
      status = 'Стрим на паузе';
    } else if (_crypto!.epoch == current.keyEpoch) {
      if (_generation != current.generation ||
          media?.connectionState == lk.ConnectionState.disconnected) {
        await connectMedia(current);
      }
      status = media?.connectionState == lk.ConnectionState.connected
          ? 'В эфире'
          : 'Подключение';
    }
    await readComments(current);
    changed();
  }

  Future<void> shareKeys(LiveStreamSnapshot current) async {
    final keys = _crypto!;
    if (keys.epoch != current.keyEpoch) {
      keys.createEpoch(current.keyEpoch);
      _outgoing.clear();
      _uploaded.clear();
      _sharedEpoch = current.keyEpoch;
    }
    final roster = await api.command('key_roster', {'stream_id': current.id});
    if (roster['epoch'] != current.keyEpoch) return;
    final devices = Map<String, dynamic>.from(roster['devices'] as Map);
    await client.updateUserDeviceKeys(additionalUsers: devices.keys.toSet());
    if (_closed) return;
    for (final user in devices.entries) {
      for (final entry in (user.value as Map).entries) {
        final deviceId = entry.key as String;
        final device = client.userDeviceKeys[user.key]?.deviceKeys[deviceId];
        final advertised = (entry.value as Map)['keys'] as Map?;
        if (device == null ||
            device.blocked ||
            !device.encryptToDevice ||
            advertised?['ed25519:$deviceId'] != device.ed25519Key ||
            advertised?['curve25519:$deviceId'] != device.curve25519Key) {
          continue;
        }
        final identity = '${user.key}/$deviceId';
        if (_uploaded.contains(identity)) continue;
        if (!_outgoing.containsKey(identity)) {
          final bundle = keys.exportBundle();
          final history = bundle['history'] as List;
          final count = (history.length + 63) ~/ 64;
          final envelopes = <Map<String, dynamic>>[];
          for (var part = 0; part < count; part++) {
            final encrypted = await client.encryption!.encryptToDeviceMessage(
              [device],
              streamKeysType,
              {
                ...bundle,
                'history': history.skip(part * 64).take(64).toList(),
                'part': part,
                'parts': count,
              },
              persistPayload: false,
            );
            final envelope = encrypted[user.key]?[deviceId];
            if (envelope == null)
              throw UserActionError('Ожидаем ключ устройства зрителя.');
            envelopes.add(envelope);
          }
          _outgoing[identity] = envelopes;
        }
        final outgoing = _outgoing[identity]!;
        for (var part = 0; part < outgoing.length; part++) {
          await api.command('key_put', {
            'stream_id': current.id,
            'epoch': _sharedEpoch,
            'user': user.key,
            'device': deviceId,
            'part': part,
            'parts': outgoing.length,
            'envelope': outgoing[part],
          });
        }
        _uploaded.add(identity);
        _outgoing.remove(identity);
      }
    }
  }

  Future<void> receiveKeys(LiveStreamSnapshot current) async {
    if (_crypto!.epoch == current.keyEpoch) return;
    await disconnectMedia();
    final value = await api.command('key_get', {'stream_id': current.id});
    if (value['epoch'] != current.keyEpoch ||
        value['owner'] != current.owner ||
        value['owner_device'] != current.ownerDevice) {
      return;
    }
    await client.updateUserDeviceKeys(additionalUsers: {current.owner});
    final device =
        client.userDeviceKeys[current.owner]?.deviceKeys[current.ownerDevice];
    final rawEnvelopes = value['envelopes'];
    if (rawEnvelopes is! List ||
        rawEnvelopes.isEmpty ||
        rawEnvelopes.length > 128) {
      throw const FormatException('stream envelopes');
    }
    Map<String, dynamic>? bundle;
    final history = <dynamic>[];
    for (var part = 0; part < rawEnvelopes.length; part++) {
      final envelope = Map<String, dynamic>.from(rawEnvelopes[part] as Map);
      if (device == null ||
          device.blocked ||
          !device.encryptToDevice ||
          envelope['sender_key'] != device.curve25519Key) {
        throw const FormatException('stream owner key');
      }
      final event = await client.encryption!.olmManager.decryptToDeviceEvent(
        mx.ToDeviceEvent(
          type: mx.EventTypes.Encrypted,
          sender: current.owner,
          content: envelope,
        ),
      );
      if (_closed) return;
      final content = event.content;
      if (event.type != streamKeysType ||
          content['part'] != part ||
          content['parts'] != rawEnvelopes.length ||
          content['history'] is! List ||
          (content['history'] as List).length > 64 ||
          content['stream'] != current.id ||
          content['epoch'] != current.keyEpoch ||
          (bundle != null &&
              (content['media'] != bundle['media'] ||
                  content['ends_at'] != bundle['ends_at']))) {
        throw const FormatException('stream key part');
      }
      bundle ??= content;
      history.addAll(content['history'] as List);
    }
    _crypto!.importBundle({...bundle!, 'history': history}, current.keyEpoch);
  }

  Future<void> readComments(LiveStreamSnapshot current) async {
    if (_crypto!.epoch == 0) return;
    // Bound each pass so a backlog cannot starve pause/leave controls.
    for (var page = 0; page < 10 && !_closed; page++) {
      if (_pauseRequested && snapshot?.state != 'paused') return;
      final value = await api.command('history', {
        'stream_id': current.id,
        'after': _historySequence,
        'head': null,
        'limit': 100,
      });
      final raw = value['messages'], head = value['head'];
      if (raw is! List ||
          raw.length > 100 ||
          head is! int ||
          head < _historySequence) {
        throw const FormatException('stream history');
      }
      final messages = raw
          .map(
            (v) => LiveStreamEncryptedComment.parse(
              Map<String, dynamic>.from(v as Map),
            ),
          )
          .toList();
      if (messages.isEmpty) break;
      await client.updateUserDeviceKeys(
        additionalUsers: messages.map((m) => m.author).toSet(),
      );
      if (_closed) return;
      for (final message in messages) {
        if (message.sequence != _historySequence + 1)
          throw const FormatException('stream sequence');
        // A roster change can race the history request. Retry after fetching its
        // new keys rather than consuming an authentic future-epoch message.
        if ((message.epoch ?? 0) > _crypto!.epoch) return;
        final device =
            client.userDeviceKeys[message.author]?.deviceKeys[message.device];
        try {
          if (device?.ed25519Key == null)
            throw const FormatException('stream author');
          final text = _crypto!.decryptComment(
            ciphertext: message.ciphertext,
            id: message.id,
            author: message.author,
            device: message.device,
            signingKey: vod.Ed25519PublicKey.fromBase64(device!.ed25519Key!),
          );
          comments.add(
            LiveStreamComment(message.sequence, message.author, text),
          );
        } catch (_) {
          // One malicious/corrupt message must not block the rest of the chat.
          comments.add(
            LiveStreamComment(
              message.sequence,
              '',
              'Не удалось проверить комментарий',
            ),
          );
        }
        _historySequence = message.sequence;
      }
      if (_historySequence >= head) break;
    }
  }

  Future<void> sendComment(String text) => serial(() async {
    final current = snapshot;
    if (current == null ||
        !current.comments ||
        _crypto!.epoch != current.keyEpoch) {
      throw UserActionError('Комментарии сейчас недоступны.');
    }
    final id = screenRequestId();
    final bytes = _crypto!.encryptComment(
      text: text,
      id: id,
      author: client.userID!,
      device: client.deviceID!,
      sign: client.encryption!.olmManager.signString,
    );
    await api.command('comment', {
      'stream_id': current.id,
      'message_id': id,
      'ciphertext': base64Encode(bytes),
    });
    await readComments(current);
    changed();
  });

  Future<void> connectMedia(LiveStreamSnapshot current) async {
    await disconnectMedia();
    if (_closed) return;
    connecting = true;
    changed();
    final grant = await api.command('grant', {
      'stream_id': current.id,
      'epoch': current.keyEpoch,
    });
    if (_closed || grant['generation'] != current.generation) return;
    final keys = await lk.BaseKeyProvider.create(
      sharedKey: false,
      discardFrameWhenCryptorNotReady: true,
    );
    _keys = keys;
    await keys.setRawKey(
      _crypto!.mediaKey!,
      participantId: grant['owner_identity'] as String,
    );
    if (_closed) {
      await disconnectMedia();
      return;
    }
    final room = routedMediaRoom(
      client,
      mediaUrl,
      lk.RoomOptions(
        encryption: lk.E2EEOptions(keyProvider: keys),
        adaptiveStream: true,
        dynacast: true,
      ),
      canRecover: () =>
          !_closed &&
          snapshot?.generation == current.generation &&
          snapshot?.state != 'paused',
    );
    media = room;
    _events = room.createListener();
    _events!.on<lk.TrackPublishedEvent>((event) {
      if (event.participant.identity != grant['owner_identity'] ||
          !allowsCallMedia(
            event.publication.encryptionType,
            event.publication.source,
            event.publication.mimeType,
            video: true,
          )) {
        unawaited(leave());
        return;
      }
      unawaited(event.publication.subscribe().catchError((Object _) {}));
    });
    _events!.on<lk.TrackSubscribedEvent>((event) {
      unawaited(applyPlayback());
      changed();
    });
    _events!.on<lk.TrackUnpublishedEvent>((_) => changed());
    _events!.on<lk.TrackMutedEvent>((_) => changed());
    _events!.on<lk.TrackUnmutedEvent>((_) => changed());
    _events!.on<lk.TrackE2EEStateEvent>((event) {
      if (event.state == lk.E2EEState.kOk) {
        decryptedVideo.add(event.publication.sid);
      } else {
        decryptedVideo.remove(event.publication.sid);
      }
      changed();
    });
    try {
      final network = routeTransportOf(client.httpClient);
      await room.connect(
        network?.websocketUrl(mediaUrl) ?? mediaUrl,
        grant['token'] as String,
        connectOptions: await routedMediaOptions(client),
      );
      if (_closed || media != room) return;
      if (room.e2eeManager == null) throw StateError('stream E2EE unavailable');
      _generation = current.generation;
      for (final participant in room.remoteParticipants.values) {
        for (final publication in participant.trackPublications.values) {
          if (participant.identity != grant['owner_identity'] ||
              !allowsCallMedia(
                publication.encryptionType,
                publication.source,
                publication.mimeType,
                video: true,
              )) {
            throw StateError('unexpected stream publication');
          }
          await publication.subscribe();
        }
      }
      if (owner) {
        await _wake.set(true);
        if (_closed || media != room || _background) {
          await _wake.set(false);
          return;
        }
        await room.localParticipant!.setMicrophoneEnabled(microphoneOn);
        for (final publication
            in room.localParticipant!.audioTrackPublications) {
          if (publication.track != null)
            observeSource(room, publication.track!);
        }
        if (cameraOn) await publishCamera();
      }
    } finally {
      connecting = false;
      changed();
    }
  }

  Future<void> publishCamera() async {
    final room = media;
    if (room == null || _closed) return;
    final stream = await captureCamera(
      backCamera ? 'environment' : 'user',
      quality,
    );
    final options = lk.CameraCaptureOptions(
      cameraPosition: backCamera
          ? lk.CameraPosition.back
          : lk.CameraPosition.front,
      params: lk.VideoParameters(
        dimensions: lk.VideoDimensions(quality.width, quality.height),
        encoding: lk.VideoEncoding(
          maxBitrate: quality.bitrate,
          maxFramerate: quality.fps,
        ),
      ),
    );
    // Same strict-facing capture path as video calls; audio is never replaced.
    // ignore: invalid_use_of_internal_member
    final track = lk.LocalVideoTrack(
      lk.TrackSource.camera,
      stream,
      stream.getVideoTracks().single,
      options,
    );
    try {
      if (_closed ||
          media != room ||
          _background ||
          snapshot?.state == 'paused') {
        await track.stop();
        return;
      }
      observeSource(room, track);
      await room.localParticipant!.publishVideoTrack(
        track,
        publishOptions: lk.VideoPublishOptions(
          simulcast: true,
          videoEncoding: options.params.encoding,
        ),
      );
    } catch (_) {
      await track.stop();
      await track.dispose();
      rethrow;
    }
  }

  void observeSource(lk.Room room, lk.LocalTrack track) {
    final source = track.mediaStreamTrack;
    final previousMute = source.onMute, previousEnd = source.onEnded;
    void interrupted() {
      if (_closed ||
          media != room ||
          !owner ||
          _pauseRequested ||
          _changingVideo)
        return;
      if (track.source == lk.TrackSource.camera && !cameraOn) return;
      if (track.source == lk.TrackSource.microphone && !microphoneOn) return;
      unawaited(pauseForCall().catchError((Object _) {}));
    }

    source.onMute = () {
      previousMute?.call();
      interrupted();
    };
    source.onEnded = () {
      previousEnd?.call();
      interrupted();
    };
  }

  Future<void> removeCamera() async {
    final participant = media?.localParticipant;
    if (participant == null) return;
    for (final publication in participant.videoTrackPublications.toList()) {
      await participant.removePublishedTrack(publication.sid);
    }
  }

  Future<void> camera(bool enabled) => serial(() async {
    if (!owner || enabled == cameraOn) return;
    final previous = cameraOn;
    cameraOn = enabled;
    try {
      if (enabled && !paused) await publishCamera();
      if (!enabled) await removeCamera();
    } catch (_) {
      cameraOn = previous;
      rethrow;
    } finally {
      changed();
    }
  });
  Future<void> microphone(bool enabled) => serial(() async {
    if (!owner) return;
    final previous = microphoneOn;
    microphoneOn = enabled;
    try {
      await media?.localParticipant?.setMicrophoneEnabled(
        paused ? false : enabled,
      );
    } catch (_) {
      microphoneOn = previous;
      rethrow;
    } finally {
      changed();
    }
  });
  Future<void> switchCamera() => serial(() async {
    if (!owner) return;
    final previous = backCamera;
    _changingVideo = true;
    try {
      await removeCamera();
      backCamera = !backCamera;
      if (cameraOn && !paused) await publishCamera();
    } catch (_) {
      backCamera = previous;
      try {
        if (cameraOn && !paused) await publishCamera();
      } catch (_) {
        cameraOn = false;
      }
      rethrow;
    } finally {
      _changingVideo = false;
      changed();
    }
  });
  Future<void> setQuality(VideoQuality value) => serial(() async {
    if (owner) {
      _changingVideo = true;
      final previous = quality;
      try {
        await removeCamera();
        quality = value;
        if (cameraOn && !paused) await publishCamera();
      } catch (_) {
        quality = previous;
        try {
          if (cameraOn && !paused) await publishCamera();
        } catch (_) {
          cameraOn = false;
        }
        rethrow;
      } finally {
        _changingVideo = false;
      }
    } else {
      quality = value;
      await applyPlayback();
    }
    changed();
  });
  Future<void> sound(bool enabled) => serial(() async {
    speakerOn = enabled;
    await applyPlayback();
    changed();
  });
  Future<void> applyPlayback() async {
    for (final participant
        in media?.remoteParticipants.values ?? <lk.RemoteParticipant>[]) {
      for (final publication in participant.audioTrackPublications) {
        final track = publication.track?.mediaStreamTrack;
        if (track != null) await setCallTrackVolume(track, speakerOn ? 1 : 0);
      }
      for (final publication in participant.videoTrackPublications) {
        await publication.setVideoQuality(switch (quality) {
          VideoQuality.low => lk.VideoQuality.LOW,
          VideoQuality.medium => lk.VideoQuality.MEDIUM,
          _ => lk.VideoQuality.HIGH,
        });
      }
    }
  }

  Future<void> pauseForCall() {
    if (snapshot == null) return Future.value();
    _pauseRequested = true;
    // Stop the local sources before waiting for a queued network operation.
    for (final publication
        in media?.localParticipant?.trackPublications.values ??
            <lk.LocalTrackPublication>[]) {
      publication.track?.mediaStreamTrack.enabled = false;
    }
    changed();
    return serial(() async {
      if (snapshot == null) return;
      if (!owner) {
        await leaveInternal();
        return;
      }
      await disconnectMedia();
      if (snapshot!.state != 'paused') {
        adopt(
          await api.command('pause', {
            'stream_id': snapshot!.id,
            'revision': snapshot!.revision,
          }),
        );
      }
      status = 'Стрим на паузе';
      changed();
    });
  }

  Future<void> resume() => serial(() async {
    if (!owner || snapshot?.state != 'paused') return;
    if (callActive()) {
      throw UserActionError('Сначала завершите текущий звонок.');
    }
    adopt(
      await api.command('resume', {
        'stream_id': snapshot!.id,
        'revision': snapshot!.revision,
      }),
    );
    _pauseRequested = false;
    await refresh();
  });

  Future<void> disconnectMedia() async {
    await _wake.set(false);
    final room = media;
    media = null;
    _generation = null;
    decryptedVideo.clear();
    await _events?.dispose();
    _events = null;
    try {
      await room?.disconnect();
    } finally {
      await room?.dispose();
      await _keys?.keyProvider.dispose();
      _keys = null;
    }
  }

  Future<void> leave() => serial(() => leaveInternal());
  Future<void> leaveInternal({bool notifyServer = true}) async {
    final current = snapshot, wasOwner = owner;
    _pauseRequested = false;
    snapshot = null;
    _timer?.cancel();
    _timer = null;
    await disconnectMedia();
    _crypto?.clear();
    _crypto = null;
    _outgoing.clear();
    _uploaded.clear();
    comments.clear();
    _historySequence = 0;
    if (current != null && notifyServer) {
      try {
        await api.command(wasOwner ? 'stop' : 'leave', {
          'stream_id': current.id,
          if (wasOwner) 'revision': current.revision,
        });
      } catch (_) {
        /* lease/deadline is the server fallback */
      }
    }
    changed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closed) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _background = true;
      if (owner && active && snapshot?.state != 'paused') {
        unawaited(
          serial(() async {
            await disconnectMedia();
          }),
        );
      }
    } else if (state == AppLifecycleState.resumed) {
      _background = false;
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    WidgetsBinding.instance.removeObserver(this);
    _closed = true;
    _timer?.cancel();
    _directoryTimer?.cancel();
    await _queue;
    await leaveInternal();
    api.close();
    super.dispose();
  }
}
