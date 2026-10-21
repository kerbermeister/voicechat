import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'matrix_probe.dart';
import 'user_action_error.dart';

const maxAttachmentBytes = 10 * 1024 * 1024;

/// Durable outbox in the same encrypted store as the device keys; never account data on the server.
class ChatActions extends ChangeNotifier {
  final Client client;
  final List<Map<String, dynamic>> pending = [];
  StreamSubscription<dynamic>? _sync;
  Timer? _retry;
  bool _sending = false;
  bool _closed = false;
  Future<void> _writes = Future.value();
  ChatActions(this.client);
  static const _storageKey = 'dev.voicechat.local.outbox';

  Future<void> open() async {
    final data = (await client.database.getAccountData())[_storageKey]?.content;
    pending.addAll(
      (data?['items'] as List? ?? []).map(
        (v) => Map<String, dynamic>.from(v as Map),
      ),
    );
    _sync = client.onSync.stream.listen((_) => unawaited(flush()));
    _retry = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(flush()),
    );
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

  Future<void> enqueue(
    Room room,
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
    Event? reply,
    String? edit,
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
  }

  Future<void> text(
    Room room,
    String text, {
    Event? reply,
    String? edit,
  }) async {
    text = text.trim();
    if (text.isEmpty || text.length > 16000) {
      throw UserActionError('Введите текст до 16 000 символов.');
    }
    await enqueue(
      room,
      {'msgtype': MessageTypes.Text, 'body': text},
      reply: reply,
      edit: edit,
    );
  }

  Future<void> attachment(Room room, MatrixFile file, {Event? reply}) async {
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
    }, reply: reply);
  }

  Future<void> flush() async {
    if (_closed || _sending || pending.isEmpty) return;
    _sending = true;
    try {
      for (final item in pending.toList()) {
        if (_closed) break;
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
          final content = Map<String, dynamic>.from(item['content'] as Map);
          final reply = item['reply'] == null
              ? null
              : await room.getEventById(item['reply'] as String);
          if (item['reply'] != null && reply == null) {
            throw StateError('Reply unavailable');
          }
          String? id;
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
            );
          } else {
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
        } catch (error) {
          if (_closed) break;
          item['error'] = error is UserActionError
              ? error.message
              : 'Нет подтверждения отправки. Повторим при восстановлении связи.';
          await _save();
          break; // Preserve ordering and the transaction ID on retries.
        }
        if (!_closed) notifyListeners();
      }
    } catch (_) {
      // Preserve the durable item if storage or network fails during a retry.
    } finally {
      _sending = false;
      if (!_closed) notifyListeners();
    }
  }

  Future<void> cancel(String id) async {
    if (_sending) {
      throw UserActionError('Дождитесь завершения текущей попытки отправки.');
    }
    final index = pending.indexWhere((item) => item['id'] == id);
    if (index < 0) return;
    final item = pending.removeAt(index);
    try {
      await _save();
    } catch (_) {
      pending.insert(index, item);
      rethrow;
    }
    notifyListeners();
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

List<Event> visibleMessages(Timeline timeline, String query) {
  final search = query.trim().toLowerCase();
  return timeline.events
      .where(
        (event) =>
            (event.type == EventTypes.Message ||
                event.type == EventTypes.Encrypted) &&
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
