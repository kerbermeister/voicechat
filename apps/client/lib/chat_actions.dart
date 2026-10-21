import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'matrix_probe.dart';
import 'user_action_error.dart';
import 'media_policy.dart';
import 'transport.dart';
import 'local_store.dart';
import 'picked_file.dart';

const maxAttachmentBytes = 10 * 1024 * 1024;

/// Durable outbox in the same encrypted store as the device keys; never account data on the server.
class ChatActions extends ChangeNotifier {
  final Client client;
  final String? policyUrl;
  final void Function()? onSent;
  final _opened = DateTime.now().millisecondsSinceEpoch;
  MediaPolicy policy = const MediaPolicy();
  DateTime _policyChecked = DateTime(1970);
  bool _loadingPolicy = false;
  final List<Map<String, dynamic>> pending = [];
  StreamSubscription<dynamic>? _sync;
  Timer? _retry;
  bool _sending = false;
  bool _closed = false;
  final _preparing = <String>{};
  String? _activeItem;
  String? _publishing;
  Future<void> _writes = Future.value();
  ChatActions(this.client, {this.policyUrl, this.onSent});
  static const _storageKey = 'dev.voicechat.local.outbox';

  Future<void> refreshPolicy() async {
    if (policyUrl == null ||
        _closed ||
        _loadingPolicy ||
        DateTime.now().difference(_policyChecked).inSeconds < 30) {
      return;
    }
    _loadingPolicy = true;
    _policyChecked = DateTime.now();
    try {
      final response = await client.httpClient
          .get(secureEndpoint('$policyUrl/config'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200 || response.bodyBytes.length > 8192) {
        throw const FormatException('Policy unavailable');
      }
      final next = MediaPolicy.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
      if (_closed) return;
      await (_writes = _writes
          .catchError((Object _) {})
          .then(
            (_) => client.database.storeAccountData(
              'dev.voicechat.local.policy',
              next.toJson(),
            ),
          ));
      if (_closed) return;
      policy = next;
      notifyListeners();
    } catch (_) {
      // Keep the last valid policy for offline sending; never erase queued messages.
    } finally {
      _loadingPolicy = false;
    }
  }

  Future<void> open() async {
    if (policyUrl != null) {
      final stored =
          (await client.database.getAccountData())['dev.voicechat.local.policy']
              ?.content;
      if (stored != null) policy = MediaPolicy.fromJson(stored);
      await refreshPolicy();
    }
    final data = (await client.database.getAccountData())[_storageKey]?.content;
    pending.addAll(
      (data?['items'] as List? ?? []).map(
        (v) => Map<String, dynamic>.from(v as Map),
      ),
    );
    _sync = client.onSync.stream.listen((_) => unawaited(flush()));
    _retry = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(flush());
      unawaited(refreshPolicy());
    });
    unawaited(flush());
  }

  Future<void> _save() {
    final snapshot = jsonDecode(jsonEncode(pending)) as List;
    return _writes = _writes
        .catchError((Object _) {})
        .then(
          (_) => client.database.storeAccountData(_storageKey, {
            'items': snapshot,
          }),
        );
  }

  Future<String> enqueue(
    Room room,
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
    Event? reply,
    String? edit,
    bool preparing = false,
  }) async {
    if (_closed) {
      throw UserActionError('Хранилище закрывается. Повторите после входа.');
    }
    if (!room.encrypted || room.membership != Membership.join) {
      throw UserActionError(
        'Отправка возможна только в зашифрованный чат, в который вы вступили.',
      );
    }
    if (pending.length >= 100) {
      throw UserActionError('В очереди уже 100 сообщений. Дождитесь отправки.');
    }
    final item = <String, dynamic>{
      'id': client.generateUniqueTransactionId(),
      'room': room.id,
      'content': content,
      'type': type,
      'created': DateTime.now().millisecondsSinceEpoch,
      if (reply != null) 'reply': reply.eventId,
      if (edit != null) 'edit': edit,
      if (preparing) 'preparing': true,
    };
    pending.add(item);
    try {
      await _save();
    } catch (_) {
      pending.remove(item);
      rethrow;
    }
    notifyListeners();
    unawaited(flush());
    return item['id'] as String;
  }

  Future<void> file(
    Room room,
    PickedFile source,
    String caption, {
    Event? reply,
    bool videoNote = false,
    int? duration,
    void Function(double)? progress,
    bool Function()? cancelled,
  }) async {
    await refreshPolicy();
    final video = source.mime.startsWith('video/');
    final limit = video ? policy.videoMaxBytes : policy.fileMaxBytes;
    if (source.size < 1 ||
        source.size > limit ||
        caption.trim().length > policy.textMaxLength ||
        (videoNote &&
            (!video ||
                duration == null ||
                duration > policy.videoNoteMaxSeconds * 1000))) {
      throw UserActionError(
        'Проверьте размер файла, длину подписи и записи. Лимит: ${(limit / 1048576).floor()} МБ.',
      );
    }
    final id = await enqueue(
      room,
      {
        'msgtype': 'dev.voicechat.file',
        'body': source.name,
        'caption': caption.trim(),
        'mime': source.mime,
        'size': source.size,
        'video_note': videoNote,
        if (duration != null) 'duration': duration,
        'parts': <Map<String, dynamic>>[],
      },
      reply: reply,
      preparing: true,
    );
    final item = pending.firstWhere((i) => i['id'] == id);
    _preparing.add(id);
    try {
      for (
        var start = 0, index = 0;
        start < source.size;
        start += fileChunkBytes, index++
      ) {
        if (_closed || item['cancelled'] == true || cancelled?.call() == true) {
          throw UserActionError('Подготовка отменена.');
        }
        final end = (start + fileChunkBytes).clamp(0, source.size);
        final bytes = await source.read(start, end);
        if (bytes.length != end - start) {
          throw const FormatException('File changed during reading');
        }
        final encrypted = await MatrixFile(
          bytes: bytes,
          name: 'part',
        ).encrypt();
        if (_closed) throw StateError('Store closed');
        await writeBlob(client.clientName, '$id/$index', encrypted.data);
        if (item['cancelled'] == true || cancelled?.call() == true) {
          throw UserActionError('Подготовка отменена.');
        }
        (item['content']['parts'] as List).add({
          'size': bytes.length,
          'file': encryptedDescriptor(encrypted),
        });
        await _save();
        progress?.call(end / source.size);
      }
      item.remove('preparing');
      await _save();
    } catch (_) {
      if (!_closed) {
        pending.remove(item);
        await _save();
        await _deleteParts(item);
      }
      rethrow;
    } finally {
      _preparing.remove(id);
      if (!_closed) notifyListeners();
    }
    unawaited(flush());
  }

  Future<void> _uploadFile(Map<String, dynamic> item) async {
    final parts = item['content']['parts'] as List;
    for (var i = 0; i < parts.length; i++) {
      if (_closed) throw StateError('Store closed');
      if (item['cancelled'] == true) throw StateError('Cancelled');
      final file = parts[i]['file'] as Map;
      if (file['url'] != null) continue;
      final bytes = await readBlob(client.clientName, '${item['id']}/$i');
      if (bytes == null) throw StateError('Encrypted file part unavailable');
      final uri = await client.uploadContent(
        bytes,
        filename: 'part',
        contentType: 'application/octet-stream',
      );
      if (_closed) throw StateError('Store closed');
      file['url'] = uri.toString();
      await _save();
      notifyListeners();
    }
  }

  Future<void> _deleteParts(Map<String, dynamic> item) async {
    if (item['content']['msgtype'] != 'dev.voicechat.file') return;
    final count =
        ((item['content']['size'] as int) + fileChunkBytes - 1) ~/
        fileChunkBytes;
    for (var i = 0; i < count; i++) {
      await deleteBlob(client.clientName, '${item['id']}/$i');
    }
  }

  Future<void> text(
    Room room,
    String text, {
    Event? reply,
    String? edit,
  }) async {
    await refreshPolicy();
    text = text.trim();
    if (text.isEmpty || text.length > policy.textMaxLength) {
      throw UserActionError(
        'Введите текст до ${policy.textMaxLength} символов.',
      );
    }
    await enqueue(
      room,
      {'msgtype': MessageTypes.Text, 'body': text},
      reply: reply,
      edit: edit,
    );
  }

  Future<void> attachment(
    Room room,
    MatrixFile file, {
    Event? reply,
    List<int>? waveform,
    String caption = '',
  }) async {
    if (caption.trim().length > policy.textMaxLength) {
      throw UserActionError('Подпись слишком длинная.');
    }
    if (waveform != null &&
        (file is! MatrixAudioFile ||
            waveform.isEmpty ||
            waveform.length > 128 ||
            waveform.any((n) => n < 0 || n > 1024))) {
      throw UserActionError('Некорректные данные голосового сообщения.');
    }
    if (file.bytes.isEmpty || file.size > maxAttachmentBytes) {
      throw UserActionError('Размер вложения: от 1 байта до 10 МБ.');
    }
    if (file.msgType != MessageTypes.Image &&
        file.msgType != MessageTypes.Audio) {
      throw UserActionError(
        'Поддерживаются изображения и голосовые сообщения.',
      );
    }
    await enqueue(room, {
      'msgtype': file.msgType,
      'body': file.name,
      'bytes': base64Encode(file.bytes),
      'mime': file.mimeType,
      if (file is MatrixAudioFile) 'duration': file.duration,
      if (waveform != null) 'dev.voicechat.waveform': waveform,
      if (caption.trim().isNotEmpty) 'dev.voicechat.caption': caption.trim(),
    }, reply: reply);
  }

  Future<void> album(
    Room room,
    List<MatrixImageFile> photos,
    String caption, {
    Event? reply,
  }) async {
    await refreshPolicy();
    if (photos.isEmpty ||
        photos.length > policy.photoMaxCount ||
        caption.trim().length > policy.textMaxLength) {
      throw UserActionError('Проверьте число фотографий и длину подписи.');
    }
    if (photos.any(
      (p) =>
          p.bytes.isEmpty ||
          p.size > policy.photoMaxBytes ||
          p.mimeType != 'image/jpeg',
    )) {
      throw UserActionError('Фотография превышает допустимый размер.');
    }
    await enqueue(room, {
      'msgtype': 'dev.voicechat.album',
      'body': caption.trim().isEmpty
          ? 'Фотографии · ${photos.length}'
          : caption.trim(),
      'caption': caption.trim(),
      'images': photos
          .map(
            (p) => {
              'bytes': base64Encode(p.bytes),
              'body': p.name,
              'info': p.info,
            },
          )
          .toList(),
    }, reply: reply);
  }

  Future<void> _uploadAlbum(Map<String, dynamic> item, Room room) async {
    final images = item['content']['images'] as List;
    for (final image in images) {
      if (_closed) throw StateError('Store closed');
      if (!image.containsKey('bytes')) continue;
      final file = MatrixImageFile(
        bytes: base64Decode(image['bytes'] as String),
        name: image['body'] as String,
        mimeType: 'image/jpeg',
      );
      final encrypted = await file.encrypt();
      final upload = encrypted.toMatrixFile();
      final uri = await client.uploadContent(
        upload.bytes,
        filename: upload.name,
        contentType: upload.mimeType,
      );
      if (_closed) throw StateError('Store closed');
      final descriptor = {
        'url': uri.toString(),
        'v': 'v2',
        'key': {
          'alg': 'A256CTR',
          'ext': true,
          'k': encrypted.k,
          'key_ops': ['encrypt', 'decrypt'],
          'kty': 'oct',
        },
        'iv': encrypted.iv,
        'hashes': {'sha256': encrypted.sha256},
      };
      image['file'] = descriptor;
      image['msgtype'] = MessageTypes.Image;
      image.remove('bytes');
      await _save();
    }
    // Uploading can take time: recheck recipients before publishing any file keys.
    await authorizedDevices(room).timeout(const Duration(seconds: 8));
    await client.encryption!.keyManager.clearOrUseOutboundGroupSession(
      room.id,
      wipe: true,
    );
  }

  Future<void> flush() async {
    if (_closed || _sending || pending.isEmpty) return;
    _sending = true;
    try {
      for (final item in pending.toList()) {
        if (_closed) break;
        if (!pending.contains(item)) continue;
        if (item['cancelled'] == true && !_preparing.contains(item['id'])) {
          pending.remove(item);
          await _save();
          await _deleteParts(item);
          continue;
        }
        if (item['preparing'] == true) break;
        _activeItem = item['id'] as String;
        try {
          final room = client.getRoomById(item['room'] as String);
          if (room == null || !room.encrypted) {
            throw StateError('Room unavailable');
          }
          await authorizedDevices(room).timeout(const Duration(seconds: 8));
          if (_closed) break;
          await client.encryption!.keyManager.clearOrUseOutboundGroupSession(
            room.id,
            wipe: true,
          );
          if (item['content']['msgtype'] == 'dev.voicechat.album') {
            await _uploadAlbum(item, room);
          }
          if (item['content']['msgtype'] == 'dev.voicechat.file') {
            await _uploadFile(item);
            await authorizedDevices(room).timeout(const Duration(seconds: 8));
            await client.encryption!.keyManager.clearOrUseOutboundGroupSession(
              room.id,
              wipe: true,
            );
          }
          if (_closed) break;
          if (item['cancelled'] == true) throw StateError('Cancelled');
          final content = Map<String, dynamic>.from(item['content'] as Map);
          final reply = item['reply'] == null
              ? null
              : await room.getEventById(item['reply'] as String);
          if (item['reply'] != null && reply == null) {
            throw StateError('Reply unavailable');
          }
          String? id;
          if (item['cancelled'] == true) throw StateError('Cancelled');
          _publishing = item['id'] as String;
          if (content.containsKey('bytes')) {
            final bytes = base64Decode(content['bytes'] as String);
            final file = content['msgtype'] == MessageTypes.Audio
                ? MatrixAudioFile(
                    bytes: bytes,
                    name: content['body'] as String,
                    mimeType: content['mime'] as String,
                    duration: content['duration'] as int?,
                  )
                : MatrixImageFile(
                    bytes: bytes,
                    name: content['body'] as String,
                    mimeType: content['mime'] as String,
                  );
            id = await room.sendFileEvent(
              file,
              txid: item['id'] as String,
              inReplyTo: reply,
              extraContent: {
                if (content.containsKey('dev.voicechat.waveform'))
                  'dev.voicechat.waveform': content['dev.voicechat.waveform'],
                if (content.containsKey('dev.voicechat.caption'))
                  'dev.voicechat.caption': content['dev.voicechat.caption'],
              },
            );
          } else {
            if (utf8.encode(jsonEncode(content)).length > 44000) {
              throw UserActionError(
                'Сообщение слишком большое для сервера. Сократите подпись или разделите альбом.',
              );
            }
            id = await room.sendEvent(
              content,
              type: item['type'] as String,
              txid: item['id'] as String,
              inReplyTo: reply,
              editEventId: item['edit'] as String?,
            );
          }
          if (_closed) break;
          if (id == null) throw StateError('Send not confirmed');
          pending.remove(item);
          await _save();
          if ((item['created'] as int) >= _opened &&
              item['type'] == EventTypes.Message) {
            onSent?.call();
          }
          await _deleteParts(item);
        } catch (error) {
          _publishing = null;
          if (_closed) break;
          if (item['cancelled'] == true) {
            pending.remove(item);
            await _save();
            await _deleteParts(item);
            continue;
          }
          item['error'] = error is UserActionError
              ? error.message
              : 'Нет подтверждения отправки. Повторим при восстановлении связи.';
          await _save();
          break; // Preserve ordering and the transaction ID on retries.
        }
        _publishing = null;
        if (!_closed) notifyListeners();
      }
    } catch (_) {
      // Preserve the durable item if storage or network fails during a retry.
    } finally {
      _sending = false;
      _activeItem = null;
      _publishing = null;
      if (!_closed) notifyListeners();
    }
  }

  Future<void> cancel(String id) async {
    if (_publishing == id) {
      throw UserActionError(
        'Сервер уже принимает сообщение. После отправки его можно удалить.',
      );
    }
    final index = pending.indexWhere((item) => item['id'] == id);
    if (index < 0) return;
    if (_activeItem == id || _preparing.contains(id)) {
      pending[index]['cancelled'] = true;
      await _save();
      notifyListeners();
      return;
    }
    final item = pending.removeAt(index);
    try {
      await _save();
    } catch (_) {
      pending.insert(index, item);
      rethrow;
    }
    notifyListeners();
    await _deleteParts(item);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _retry?.cancel();
    await _sync?.cancel();
    try {
      await _writes;
    } finally {
      dispose();
    }
  }
}

Map<String, dynamic> encryptedDescriptor(EncryptedFile encrypted) => {
  'v': 'v2',
  'key': {
    'alg': 'A256CTR',
    'ext': true,
    'k': encrypted.k,
    'key_ops': ['encrypt', 'decrypt'],
    'kty': 'oct',
  },
  'iv': encrypted.iv,
  'hashes': {'sha256': encrypted.sha256},
};

List<Event> visibleMessages(Timeline timeline, String query) {
  final search = query.trim().toLowerCase();
  return timeline.events
      .where(
        (event) =>
            (event.type == EventTypes.Message ||
                event.type == EventTypes.Encrypted &&
                    event.messageType == MessageTypes.BadEncrypted) &&
            event.relationshipType != RelationshipTypes.edit &&
            event.status.isSent,
      )
      .where(
        (event) =>
            search.isEmpty ||
            (!event.redacted &&
                event
                    .getDisplayEvent(timeline)
                    .calcUnlocalizedBody(hideReply: true)
                    .toLowerCase()
                    .contains(search)),
      )
      .toList();
}

/// A receipt on a later event also acknowledges earlier messages in the loaded timeline.
bool messageIsRead(Event event, Timeline timeline) {
  final index = timeline.events.indexWhere((e) => e.eventId == event.eventId);
  if (index < 0) return false;
  return event.room.receiptState.global.otherUsers.entries.any((receipt) {
    if (receipt.key == event.room.client.userID) return false;
    final readIndex = timeline.events.indexWhere(
      (e) => e.eventId == receipt.value.eventId,
    );
    return readIndex >= 0 && readIndex <= index;
  });
}
