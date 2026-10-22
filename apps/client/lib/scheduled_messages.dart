import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:matrix/matrix.dart';
import 'transport.dart';
import 'user_action_error.dart';

void validateSchedule(DateTime due, int maximumSeconds, {DateTime? now}) {
  final remaining = due.difference(now ?? DateTime.now());
  if (remaining <= Duration.zero ||
      remaining > Duration(seconds: maximumSeconds)) {
    throw UserActionError(
      'Выберите будущее время в пределах ${maximumSeconds ~/ 3600} ч.',
    );
  }
}

String scheduledAudienceDigest(
  Iterable<String> members,
  Map<String, dynamic> keys,
) {
  final users = members.toList()..sort();
  final identities = <List<String>>[];
  for (final user in users) {
    final devices = Map<String, dynamic>.from(keys[user] as Map? ?? {});
    for (final device in devices.keys.toList()..sort()) {
      final identity = devices[device]['keys'] as Map;
      identities.add([
        user,
        device,
        identity['curve25519:$device'] as String,
        identity['ed25519:$device'] as String,
      ]);
    }
  }
  return sha256
      .convert(utf8.encode(jsonEncode([users, identities])))
      .toString();
}

class ScheduleRejected extends UserActionError {
  ScheduleRejected(super.message);
}

String scheduledError(String? code) => switch (code) {
  'invalid_schedule_time' =>
    'Время прошло или превышает серверный лимит. Выберите новое время.',
  'audience_changed' || 'device_key_changed' =>
    'Состав участников или ключи изменились. Проверьте устройства и запланируйте заново.',
  'device_revoked' || 'account_revoked' =>
    'Устройство отправителя отозвано. Сообщение не опубликовано.',
  'not_joined' || 'contact_not_accepted' || 'invalid_direct_room' =>
    'Доступ к чату изменился. Сообщение не опубликовано.',
  'already_publishing' => 'Отправка уже началась. Отменить её сейчас нельзя.',
  'too_many_scheduled_messages' =>
    'Лимит — 100 запланированных сообщений. Отмените ненужные.',
  _ =>
    'Сервис расписания недоступен или действие запрещено. Сообщение сохранено.',
};

class ScheduledMessages {
  final Client client;
  final String url;
  ScheduledMessages(this.client, this.url);

  Future<Map<String, dynamic>> request([Map<String, dynamic>? body]) async {
    final uri = secureEndpoint('$url/scheduled');
    final headers = {
      'Authorization': 'Bearer ${client.accessToken}',
      'Content-Type': 'application/json',
    };
    final response =
        await (body == null
                ? client.httpClient.get(uri, headers: headers)
                : client.httpClient.post(
                    uri,
                    headers: headers,
                    body: jsonEncode(body),
                  ))
            .timeout(const Duration(seconds: 20));
    if (response.bodyBytes.length > 262144) {
      throw const FormatException('Scheduled response too large');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      final message = scheduledError(data['error'] as String?);
      if ([400, 401, 403, 409].contains(response.statusCode)) {
        throw ScheduleRejected(message);
      }
      throw UserActionError(message);
    }
    return data;
  }

  String audience(Room room) {
    final members = room
        .getParticipants([
          Membership.join,
          if (room.isDirectChat) Membership.invite,
        ])
        .map((member) => member.id)
        .toSet();
    if (!members.contains(client.userID)) {
      throw StateError('Room access changed');
    }
    return scheduledAudienceDigest(members, {
      for (final user in members)
        user: {
          for (final device in client.userDeviceKeys[user]!.deviceKeys.values)
            device.deviceId!: {'keys': device.keys},
        },
    });
  }

  Future<Map<String, dynamic>> create(Map<String, dynamic> item) => request({
    'action': 'create',
    'transaction': item['id'],
    'room_id': item['room'],
    'due': item['scheduled_at'],
    'payload': item['sealed'],
    'audience': item['audience'],
  });

  Future<List<Map<String, dynamic>>> list() async =>
      ((await request())['messages'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
  Future<String> preview(String id) async {
    final response = await client.httpClient
        .get(
          secureEndpoint('$url/scheduled').replace(queryParameters: {'id': id}),
          headers: {'Authorization': 'Bearer ${client.accessToken}'},
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200 || response.bodyBytes.length > 131072) {
      throw UserActionError('Не удалось открыть зашифрованный черновик.');
    }
    final job = jsonDecode(response.body) as Map<String, dynamic>;
    if (client.userID == null ||
        job['id'] != id ||
        job['user_id'] != client.userID) {
      throw const FormatException('Wrong scheduled owner');
    }
    final payload = job['payload'] as Map?;
    if (payload == null) return 'Сообщение опубликовано или отменено.';
    final session = await client.encryption!.keyManager.loadInboundGroupSession(
      job['room_id'] as String,
      payload['session_id'] as String,
    );
    if (session?.isValid != true ||
        session!.senderKey != payload['sender_key']) {
      throw UserActionError(
        'Восстановите ключи истории на этом устройстве, чтобы открыть черновик.',
      );
    }
    // Preview has no event ID; never register its index as a received timeline event.
    final decoded =
        jsonDecode(
              session.inboundGroupSession!
                  .decrypt(payload['ciphertext'] as String)
                  .plaintext,
            )
            as Map;
    if (decoded['room_id'] != job['room_id'] ||
        decoded['type'] != EventTypes.Message) {
      throw const FormatException('Invalid scheduled message');
    }
    final content = decoded['content'] as Map;
    return [
      content['body'] as String? ?? 'Вложение',
      if (content['caption'] is String) content['caption'] as String,
      if (content['dev.voicechat.caption'] is String)
        content['dev.voicechat.caption'] as String,
    ].where((value) => value.isNotEmpty).toSet().join('\n');
  }

  Future<void> withdraw(Map<String, dynamic> item) async {
    await request({
      'action': 'withdraw',
      'transaction': item['id'],
      'room_id': item['room'],
    });
  }

  Future<void> cancel(String id) async {
    await request({'action': 'cancel', 'id': id});
  }
}
