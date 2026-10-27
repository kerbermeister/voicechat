import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as mx;
import '../contact_service.dart';
import '../matrix_probe.dart';
import '../picked_file.dart';
import '../transport.dart';
import '../file_io.dart' as io;
import '../file_save_result.dart';
import '../user_action_error.dart';
import 'capacity.dart';
import 'protocol.dart';
import 'temp_store.dart';
import 'wire.dart';

enum P2pState {
  offered,
  connecting,
  transferring,
  received,
  declined,
  cancelled,
  failed,
}

class P2pTransfer {
  final String id, roomId, peer;
  final bool outgoing;
  final List<P2pFile> files;
  final int expires;
  final List<PickedFile>? sources;
  String? device;
  P2pState state = P2pState.offered;
  P2pRoute route = P2pRoute.unknown;
  String? error;
  late final List<int> bytes = List.filled(files.length, 0);
  late final List<bool> verified = List.filled(files.length, false);
  late final List<String?> saved = List.filled(files.length, null);
  final speed = P2pSpeed();
  bool exporting = false;
  P2pWire? wire;
  P2pTransfer({
    required this.id,
    required this.roomId,
    required this.peer,
    required this.outgoing,
    required this.files,
    required this.expires,
    this.device,
    this.sources,
  });
  bool get active => [
    P2pState.offered,
    P2pState.connecting,
    P2pState.transferring,
  ].contains(state);
  String get label => switch (state) {
    P2pState.offered => outgoing ? 'Ожидаем согласия' : 'Предлагает файлы',
    P2pState.connecting => 'Подключаемся',
    P2pState.transferring => 'Передаётся',
    P2pState.received =>
      outgoing ? 'Получено и проверено' : 'Готово к сохранению',
    P2pState.declined => 'Отклонено',
    P2pState.cancelled => 'Отменено',
    P2pState.failed => 'Передача прервана',
  };
}

class P2pService extends ChangeNotifier {
  static const eventType = 'dev.voicechat.p2p.v1';
  final mx.Client client;
  final ContactService contacts;
  final String server;
  late final P2pTempStore storage = P2pTempStore(client);
  final List<P2pTransfer> transfers = [];
  final Map<String, int> _seen = {};
  final Set<List<PickedFile>> _released = {};
  P2pPolicy? policy;
  String? warning;
  bool preparing = false;
  double preparation = 0;
  bool _cancelPreparation = false, _closed = false, _checking = false;
  StreamSubscription<mx.ToDeviceEvent>? _events;
  Timer? _timer;
  Future<void> _messages = Future.value();
  final Set<Future<void>> _work = {};
  Future<void> _track(Future<void> Function() action) {
    if (_closed) return Future.error(UserActionError('Сеанс P2P закрыт.'));
    late final Future<void> work;
    work = Future<void>.sync(action).whenComplete(() => _work.remove(work));
    _work.add(work);
    return work;
  }

  P2pService(this.client, this.contacts, this.server);
  bool get busy => preparing || transfers.any((t) => t.active || t.exporting);
  int get activeRecipients =>
      transfers.where((t) => t.outgoing && t.active).length;
  int get incomingCount =>
      transfers.where((t) => !t.outgoing && t.state == P2pState.offered).length;
  void _changed() {
    if (!_closed) notifyListeners();
  }

  Future<P2pPolicy> refreshPolicy() async {
    final response = await client.httpClient
        .get(secureEndpoint('$server/config'))
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200 || response.bodyBytes.length > 8192) {
      throw UserActionError('Не удалось получить лимиты P2P.');
    }
    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Invalid policy');
    }
    policy = P2pPolicy.parse(data);
    _changed();
    if (policy == null) {
      throw UserActionError('Сервер пока не поддерживает P2P Share.');
    }
    return policy!;
  }

  Future<void> open() async {
    await storage.open();
    try {
      await refreshPolicy();
    } catch (_) {
      warning = 'P2P недоступен: проверьте соединение и настройки сервера.';
    }
    _events = client.onToDeviceEvent.stream.listen((event) {
      if (event.type != eventType || _closed) return;
      _messages = _messages.then((_) => _receive(event)).catchError((Object _) {
        // Untrusted malformed signaling never tears down other users' transfers.
      });
    });
    _timer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_track(_check).catchError((Object _) {})),
    );
  }

  Future<List<mx.DeviceKeys>> _devices(P2pTransfer t) async {
    await contacts.refresh();
    if (!contacts.available || !contacts.acceptsRoom(t.roomId, t.peer)) {
      throw UserActionError('Доступ к контакту изменился.');
    }
    final room = client.getRoomById(t.roomId);
    if (room == null) throw UserActionError('Личный диалог недоступен.');
    final devices = (await authorizedDevices(
      room,
    )).where((d) => d.userId == t.peer && d.isValid).toList();
    if (t.device != null) devices.retainWhere((d) => d.deviceId == t.device);
    if (devices.isEmpty) {
      throw UserActionError('Нет доступного проверенного устройства.');
    }
    return devices;
  }

  Future<void> _send(
    P2pTransfer t,
    String op, [
    Map<String, dynamic> payload = const {},
  ]) async {
    if (_closed) throw StateError('Closed P2P session');
    final devices = op == 'signal'
        ? client.userDeviceKeys[t.peer]?.deviceKeys.values
                  .where(
                    (d) =>
                        d.deviceId == t.device &&
                        d.directVerified &&
                        d.isValid &&
                        !d.blocked &&
                        d.encryptToDevice,
                  )
                  .toList() ??
              <mx.DeviceKeys>[]
        : await _devices(t);
    if (devices.isEmpty || !contacts.acceptsRoom(t.roomId, t.peer)) {
      throw UserActionError('Нет разрешённого устройства получателя.');
    }
    if (_closed || (!t.active && !['cancel', 'decline'].contains(op))) return;
    await client.sendToDeviceEncrypted(devices, eventType, {
      'v': 1,
      'id': t.id,
      'room': t.roomId,
      'to': t.peer,
      'op': op,
      'expires': t.expires,
      ...payload,
    }, onlyVerified: true);
  }

  Future<void> send(List<String> peers, List<PickedFile> sources) =>
      _track(() => _prepare(peers, sources));
  Future<void> _prepare(List<String> peers, List<PickedFile> sources) async {
    if (_closed || preparing) {
      throw UserActionError('Подготовка уже выполняется или сеанс закрыт.');
    }
    preparing = true;
    _cancelPreparation = false;
    preparation = 0;
    warning = null;
    _changed();
    try {
      final limits = await refreshPolicy();
      if (peers.toSet().length != peers.length ||
          !contacts.acceptedUsers.containsAll(peers) ||
          activeRecipients + peers.length > limits.maxRecipients ||
          peers.isEmpty ||
          sources.isEmpty ||
          sources.length > limits.maxFiles ||
          sources.any((f) => f.size < 0 || f.size > limits.maxBytes)) {
        throw UserActionError('Проверьте друзей и лимиты файлов/получателей.');
      }
      final total = sources.fold<int>(0, (sum, f) => sum + f.size);
      var read = 0;
      final files = <P2pFile>[];
      for (final source in sources) {
        final hash = P2pHash();
        await for (final bytes
            in source
                .range(0, source.size)
                .timeout(const Duration(seconds: 60))) {
          if (_closed || _cancelPreparation) {
            throw UserActionError('Подготовка отменена.');
          }
          hash.input.add(bytes);
          read += bytes.length;
          preparation = total == 0 ? 1 : read / total;
          _changed();
        }
        files.add(
          P2pFile.fromJson({
            'name': source.name,
            'mime': source.mime,
            'size': source.size,
            'sha256': hash.finish(),
          }),
        );
      }
      parseP2pFiles(files.map((f) => f.toJson()).toList());
      if (_closed || _cancelPreparation) {
        throw UserActionError('Подготовка отменена.');
      }
      final expiry =
          DateTime.now().millisecondsSinceEpoch + p2pInvitationSeconds * 1000;
      final batch = <P2pTransfer>[];
      for (final peer in peers) {
        final contact = contacts.requests.firstWhere(
          (r) => r.state == 'accepted' && r.peer(client.userID!) == peer,
        );
        batch.add(
          P2pTransfer(
            id: p2pId(),
            roomId: contact.roomId,
            peer: peer,
            outgoing: true,
            files: files,
            expires: expiry,
            sources: sources,
          ),
        );
      }
      transfers.addAll(batch);
      _changed();
      // One recipient's authorization/network failure never prevents the others.
      await Future.wait(
        batch.map((t) async {
          try {
            await _send(t, 'offer', {
              'files': files.map((f) => f.toJson()).toList(),
            });
          } catch (_) {
            await _stop(
              t,
              P2pState.failed,
              'Не удалось пригласить получателя.',
            );
          }
        }),
      );
    } finally {
      preparing = false;
      _changed();
    }
  }

  void cancelPreparation() {
    _cancelPreparation = true;
  }

  Future<void> accept(P2pTransfer t) => _track(() => _accept(t));
  Future<void> _accept(P2pTransfer t) async {
    if (t.outgoing || t.state != P2pState.offered) return;
    t.state = P2pState.connecting;
    _changed();
    try {
      final limits = await refreshPolicy();
      limits.validate(t.files, 1);
      if (DateTime.now().millisecondsSinceEpoch >= t.expires) {
        throw UserActionError('Приглашение истекло.');
      }
      final available = await p2pAvailableBytes();
      final required = p2pRequiredBytes(
        t.files.fold<int>(0, (sum, f) => sum + f.size),
      );
      if (available != null && available < required) {
        throw UserActionError(
          'Недостаточно места для временных файлов и сохранения.',
        );
      }
      if (_closed || !t.active) return;
      await storage.register(t.id);
      await _connect(t);
      await _send(t, 'accept');
    } catch (error) {
      await _stop(
        t,
        P2pState.failed,
        error is UserActionError ? error.message : 'Не удалось принять файлы.',
      );
      unawaited(_send(t, 'cancel').catchError((Object _) {}));
    }
  }

  Future<void> cancel(P2pTransfer t, {bool decline = false}) =>
      _track(() => _cancel(t, decline: decline));
  Future<void> _cancel(P2pTransfer t, {bool decline = false}) async {
    final wasActive = t.active;
    await _stop(t, decline ? P2pState.declined : P2pState.cancelled);
    if (wasActive) {
      unawaited(
        _send(t, decline ? 'decline' : 'cancel').catchError((Object _) {}),
      );
    }
  }

  Future<void> remove(P2pTransfer t) => _track(() => _remove(t));
  Future<void> _remove(P2pTransfer t) async {
    if (t.exporting) throw UserActionError('Дождитесь завершения сохранения.');
    await _cancel(t);
    transfers.remove(t);
    _changed();
  }

  Future<void> _stop(P2pTransfer t, P2pState state, [String? error]) async {
    t.state = state;
    t.error = error;
    _changed();
    await t.wire?.drain();
    if (!t.outgoing && !t.exporting) await storage.remove(t.id);
    await _release(t.sources);
    _changed();
  }

  Future<void> _release(List<PickedFile>? sources) async {
    if (sources == null ||
        _released.contains(sources) ||
        transfers.any((t) => identical(t.sources, sources) && t.active)) {
      return;
    }
    _released.add(sources);
    for (final source in sources) {
      await source.release();
    }
  }

  Future<void> _connect(P2pTransfer t) async {
    final credentials = await client.getTurnServer();
    if (!t.active || _closed) return;
    t.wire = P2pWire(
      files: t.files,
      sources: t.sources,
      signal: (data) => _send(t, 'signal', {'data': data}),
      store: (file, block, bytes) => storage.put(t.id, file, block, bytes),
      progress: (file, bytes, verified) {
        if (!t.active) return;
        t.bytes[file] = bytes;
        t.verified[file] = verified;
        t.speed.record(
          t.bytes.fold<int>(0, (sum, n) => sum + n),
          DateTime.now().millisecondsSinceEpoch,
        );
        t.state = P2pState.transferring;
        _changed();
      },
      route: (value) {
        t.route = value;
        _changed();
      },
      complete: () {
        if (!t.active) return;
        t.state = P2pState.received;
        _changed();
        unawaited(_release(t.sources));
      },
      failed: (reason) {
        // Defer drain until the receive callback finishes to avoid awaiting itself.
        if (t.active) {
          scheduleMicrotask(() {
            if (!_closed && t.active) {
              unawaited(_stop(t, P2pState.failed, reason));
            }
          });
        }
      },
    );
    await t.wire!.open([
      {
        'urls': credentials.uris.map((u) => u.toString()).toList(),
        'username': credentials.username,
        'credential': credentials.password,
      },
    ]);
  }

  Future<void> _receive(mx.ToDeviceEvent event) async {
    if (_closed || event.encryptedContent == null || event.content['v'] != 1) {
      return;
    }
    final data = event.content;
    if (!validP2pId(data['id']) ||
        data['to'] != client.userID ||
        data['room'] is! String ||
        data['expires'] is! int ||
        utf8.encode(jsonEncode(data)).length > 100000) {
      return;
    }
    final device = client.getUserDeviceKeysByCurve25519Key(
      event.encryptedContent!['sender_key'] as String? ?? '',
    );
    if (device == null ||
        device.userId != event.sender ||
        !device.directVerified ||
        device.blocked ||
        !device.isValid ||
        !contacts.acceptsRoom(data['room'] as String, event.sender)) {
      return;
    }
    final id = data['id'] as String;
    P2pTransfer? t;
    for (final item in transfers) {
      if (item.id == id) {
        t = item;
        break;
      }
    }
    if (data['op'] == 'offer') {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (t != null ||
          _seen.containsKey(id) ||
          (data['expires'] as int) <= now ||
          (data['expires'] as int) > now + (p2pInvitationSeconds + 30) * 1000 ||
          transfers.where((v) => !v.outgoing && v.active).length >= 16) {
        return;
      }
      final limits = await refreshPolicy();
      final files = parseP2pFiles(data['files']);
      limits.validate(files, 1);
      t = P2pTransfer(
        id: id,
        roomId: data['room'] as String,
        peer: event.sender,
        outgoing: false,
        files: files,
        expires: data['expires'] as int,
        device: device.deviceId,
      );
      await _devices(t);
      if (_closed) return;
      _seen[id] = t.expires;
      transfers.add(t);
      _changed();
      return;
    }
    if (t == null ||
        !t.active ||
        t.peer != event.sender ||
        t.roomId != data['room'] ||
        (t.device != null && t.device != device.deviceId)) {
      return;
    }
    switch (data['op']) {
      case 'accept':
        if (!t.outgoing ||
            t.state != P2pState.offered ||
            DateTime.now().millisecondsSinceEpoch >= t.expires) {
          return;
        }
        await _devices(t);
        if (_closed || t.state != P2pState.offered) return;
        t.state = P2pState.connecting;
        _changed();
        try {
          // Close the same offer on the recipient's other verified devices.
          await _send(t, 'claimed', {'device': device.deviceId});
          if (_closed || !t.active) return;
          t.device = device.deviceId;
          await _connect(t);
        } catch (_) {
          await _stop(t, P2pState.failed, 'Соединение не установлено.');
        }
      case 'claimed':
        if (!t.outgoing &&
            data['device'] is String &&
            data['device'] != client.deviceID) {
          await _stop(
            t,
            P2pState.cancelled,
            'Файлы приняты на другом устройстве.',
          );
        }
      case 'decline':
        if (t.outgoing && t.state == P2pState.offered) {
          await _stop(t, P2pState.declined);
          unawaited(_send(t, 'cancel').catchError((Object _) {}));
        }
      case 'cancel':
        await _stop(t, P2pState.cancelled);
      case 'signal':
        if (t.wire == null || data['data'] is! Map<String, dynamic>) return;
        try {
          await t.wire!.receiveSignal(data['data'] as Map<String, dynamic>);
        } catch (_) {
          await _stop(
            t,
            P2pState.failed,
            'Не удалось согласовать защищённое соединение.',
          );
        }
    }
  }

  Future<void> save(P2pTransfer t, int file) =>
      _track(() => _saveFile(t, file));
  Future<void> _saveFile(P2pTransfer t, int file) async {
    if (t.outgoing ||
        !t.verified[file] ||
        t.exporting ||
        t.state != P2pState.received) {
      return;
    }
    t.exporting = true;
    _changed();
    try {
      final meta = t.files[file];
      final result = await io.saveStreamFile(
        meta.saveName,
        meta.mime,
        meta.size,
        (from, to) => storage.range(t.id, file, meta.size, from, to),
        (_) {},
        () => _closed || t.state != P2pState.received,
      );
      t.saved[file] = switch (result) {
        FileSaveResult.saved => 'Сохранено',
        FileSaveResult.downloadStarted => 'Скачивание начато',
        FileSaveResult.cancelled => 'Сохранение отменено',
      };
    } finally {
      t.exporting = false;
      _changed();
    }
  }

  Future<void> _check() async {
    if (_closed || _checking) return;
    _checking = true;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      _seen.removeWhere((_, expires) => expires < now);
      for (final t in transfers.where((t) => t.active).toList()) {
        if (_closed) return;
        if (t.state == P2pState.offered && now >= t.expires) {
          await _stop(
            t,
            P2pState.failed,
            'Нет ответа. Оба участника должны быть онлайн.',
          );
          continue;
        }
        try {
          await _devices(t).timeout(const Duration(seconds: 10));
        } catch (_) {
          if (_closed || !t.active) continue;
          await _stop(
            t,
            P2pState.failed,
            'Доступ изменился или не удалось его проверить.',
          );
        }
      }
    } finally {
      _checking = false;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cancelPreparation = true;
    _timer?.cancel();
    for (final t in transfers) {
      t.state = P2pState.cancelled;
    }
    await _events?.cancel();
    await _messages;
    while (_work.isNotEmpty) {
      await Future.wait(_work.toList().map((f) => f.catchError((Object _) {})));
    }
    for (final t in transfers) {
      t.state = P2pState.cancelled;
      await t.wire?.drain();
    }
    for (final t in transfers) {
      await _release(t.sources);
    }
    await storage.close();
  }
}
