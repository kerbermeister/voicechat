import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart' as mx;
import 'matrix_probe.dart';
import 'transport.dart';
import 'voice_call.dart';

/// Exercises sender-specific E2EE keys delivered through encrypted Matrix
/// to-device events. Authorization changes end the call; no seamless rekey yet.
class CallProbe implements VoiceCall {
  @override
  final mx.Room chat;
  @override
  final String session;
  final String tokenUrl;
  final String livekitUrl;
  final void Function(String) status;
  final void Function()? changed;
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
  final Uint8List _senderKey = Uint8List.fromList(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  );
  final Set<String> decryptedAudioFrom = {};
  final Set<String> failedAudioFrom = {};
  Set<String>? _authorization;
  @override
  bool get isClosed => _closed;
  bool _sharing = false;
  bool _closed = false;

  String get identity => '${chat.client.userID}/${chat.client.deviceID}';
  CallProbe({
    required this.chat,
    required this.session,
    required this.tokenUrl,
    required this.livekitUrl,
    required this.status,
    this.changed,
  });

  Future<void> connect({bool microphone = true}) async {
    if (!chat.encrypted) {
      throw StateError('Call requires an encrypted Matrix room');
    }
    secureEndpoint(tokenUrl);
    secureEndpoint(livekitUrl, websocket: true);
    _keys = await lk.BaseKeyProvider.create(
      sharedKey: false,
      discardFrameWhenCryptorNotReady: true,
    );
    await _keys!.setRawKey(_senderKey, participantId: identity);
    _messages = chat.client.onToDeviceEvent.stream.listen((event) {
      unawaited(
        _receive(event).catchError((Object _) {
          status('Ключ участника отклонён');
        }),
      );
    });
    media = lk.Room(
      roomOptions: lk.RoomOptions(
        encryption: lk.E2EEOptions(keyProvider: _keys!),
      ),
    );
    _events = media!.createListener();
    _events!.on<lk.ParticipantConnectedEvent>((_) => changed?.call());
    _events!.on<lk.ParticipantDisconnectedEvent>((_) => changed?.call());
    _events!.on<lk.RoomReconnectingEvent>((_) {
      connection = 'Восстанавливаем соединение';
      status(connection);
      changed?.call();
    });
    _events!.on<lk.RoomReconnectedEvent>((_) {
      connection = 'Соединение восстановлено';
      status(connection);
      changed?.call();
    });
    _events!.on<lk.RoomDisconnectedEvent>((_) {
      connection = 'Звонок завершён';
      changed?.call();
    });
    _events!.on<lk.TrackE2EEStateEvent>((event) {
      if (event.participant.identity == identity) return;
      if (event.state == lk.E2EEState.kOk) {
        decryptedAudioFrom.add(event.participant.identity);
        connection = 'Защищённое аудио';
        status('Получено E2EE-аудио: ${decryptedAudioFrom.length}');
        changed?.call();
      } else if (event.state == lk.E2EEState.kDecryptionFailed ||
          event.state == lk.E2EEState.kMissingKey) {
        failedAudioFrom.add(event.participant.identity);
        status('Ожидаем правильный ключ участника');
      }
    });
    try {
      final response = await http.post(
        Uri.parse('$tokenUrl/token'),
        headers: {
          'Authorization': 'Bearer ${chat.client.accessToken}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'room_id': chat.id, 'session': session}),
      );
      if (response.statusCode != 200) {
        throw StateError('Call admission denied (${response.statusCode})');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['identity'] != identity) {
        throw StateError('Wrong media identity');
      }
      await media!.connect(livekitUrl, data['token'] as String);
      if (media!.e2eeManager == null) {
        throw StateError('E2EE unavailable; refusing microphone');
      }
      await shareKey().timeout(const Duration(seconds: 5));
      _resend = Timer.periodic(const Duration(seconds: 3), (_) {
        unawaited(
          shareKey().timeout(const Duration(seconds: 5)).catchError((
            Object _,
          ) async {
            await close();
            status(
              'Звонок завершён: доступ изменён или не удалось его проверить',
            );
          }),
        );
      });
      if (_closed) throw StateError('Call closed during authorization');
      if (microphone) await media!.localParticipant!.setMicrophoneEnabled(true);
      connection = 'E2EE включено · ждём медиапотоки';
      status(connection);
      changed?.call();
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> shareKey() async {
    if (_sharing || _closed) return;
    _sharing = true;
    try {
      final authorized = await authorizedDevices(chat);
      if (_closed) return;
      final current = authorized
          .map(
            (d) =>
                '${d.userId}/${d.deviceId}/${d.curve25519Key}/${d.ed25519Key}',
          )
          .toSet();
      if (_authorization != null &&
          (_authorization!.length != current.length ||
              !_authorization!.containsAll(current))) {
        // shortcut: end the call; replace with coordinated epochs before seamless rekey.
        throw StateError('Call authorization changed');
      }
      _authorization = current;
      final devices = authorized
          .where(
            (d) => media!.remoteParticipants.containsKey(
              '${d.userId}/${d.deviceId}',
            ),
          )
          .toList();
      await chat.client
          .sendToDeviceEncrypted(devices, 'dev.voicechat.probe.media_key', {
            'room_id': chat.id,
            'session': session,
            'identity': identity,
            'sender_device': chat.client.deviceID,
            'expires_at': DateTime.now()
                .add(const Duration(seconds: 20))
                .millisecondsSinceEpoch,
            'key': base64Encode(_senderKey),
          });
    } finally {
      _sharing = false;
    }
  }

  Future<void> _receive(mx.ToDeviceEvent event) async {
    if (_closed ||
        event.type != 'dev.voicechat.probe.media_key' ||
        event.encryptedContent == null) {
      return;
    }
    final data = event.content;
    if (data['room_id'] != chat.id || data['session'] != session) return;
    if (!(media?.remoteParticipants.containsKey(data['identity']) ?? false)) {
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
    final members = await chat.client.getJoinedMembersByRoom(chat.id);
    if (_closed || !(members?.containsKey(event.sender) ?? false)) return;
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

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _resend?.cancel();
    await _messages?.cancel();
    await _events?.dispose();
    await media?.disconnect();
    await media?.dispose();
    _senderKey.fillRange(0, _senderKey.length, 0);
    media = null;
    connection = 'Звонок завершён';
    changed?.call();
  }
}
