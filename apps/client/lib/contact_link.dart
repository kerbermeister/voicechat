import 'dart:convert';
import 'dart:async';
import 'package:matrix/matrix.dart';
import 'contact_service.dart';
import 'matrix_probe.dart';
import 'scheduled_messages.dart';
import 'transport.dart';
import 'user_action_error.dart';

final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

Uri contactLinkUrl(Uri origin, String token) {
  if (!_tokenPattern.hasMatch(token)) {
    throw const FormatException('Invalid invitation');
  }
  secureEndpoint(origin.origin);
  return Uri.parse('${origin.origin}/').replace(fragment: '/contact/$token');
}

String contactLinkToken(String value, Uri origin) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !['https', 'http'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.origin != origin.origin ||
      uri.path != '/' ||
      uri.hasQuery ||
      !uri.fragment.startsWith('/contact/')) {
    throw UserActionError(
      'Вставьте ссылку-приглашение с этого сервера VoiceChat.',
    );
  }
  secureEndpoint(uri.removeFragment().toString());
  final token = uri.fragment.substring('/contact/'.length);
  if (!_tokenPattern.hasMatch(token)) {
    throw UserActionError('Ссылка-приглашение повреждена.');
  }
  return token;
}

String contactLinkError(String? code) => switch (code) {
  'link_used' => 'Этим приглашением уже воспользовался другой человек.',
  'invalid_link' => 'Приглашение не найдено или ссылка повреждена.',
  'invalid_user' => 'Нельзя принять собственное приглашение.',
  'link_limit' => 'Можно создать до 100 ссылок за сутки. Попробуйте позже.',
  'audience_changed' || 'device_key_changed' || 'device_revoked' =>
    'Контакт добавлен, но ключи устройств изменились. Приветствие не отправлено. Откройте чат и проверьте устройства.',
  _ =>
    'Не удалось завершить приглашение. Проверьте связь и повторите: контакт и приветствие не продублируются.',
};

class ContactLinks {
  final MatrixProbe probe;
  final ContactService contacts;
  final Uri origin;
  static const pendingKey = 'dev.voicechat.local.contactLink';
  ContactLinks(this.probe, this.contacts, this.origin);
  Client get client => probe.client;

  Future<Map<String, dynamic>> request(Map<String, dynamic> body) async {
    final response = await client.httpClient
        .post(
          secureEndpoint('${contacts.url}/contact-links'),
          headers: {
            'Authorization': 'Bearer ${client.accessToken}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 25));
    if (response.bodyBytes.length > 16384) {
      throw const FormatException('Invitation response too large');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw UserActionError(contactLinkError(data['error'] as String?));
    }
    return data;
  }

  Future<Uri> create() async => contactLinkUrl(
    origin,
    (await request({'action': 'create'}))['token'] as String,
  );

  Future<Map<String, dynamic>> inspect(String token) async {
    final data = await request({'action': 'inspect', 'token': token});
    if (data['owner'] is! String ||
        !(data['owner'] as String).startsWith('@') ||
        data['id'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(data['id'] as String) ||
        data['claimed'] is! bool ||
        data['accepted'] is! bool ||
        data['prepared'] is! bool ||
        data['room_id'] != null &&
            (data['room_id'] is! String ||
                !(data['room_id'] as String).startsWith('!'))) {
      throw const FormatException('Invalid invitation');
    }
    return data;
  }

  Future<String?> pending() async =>
      (await client.database.getAccountData())[pendingKey]?.content['token']
          as String?;

  Future<Room> accept(String token) async {
    var link = await inspect(token);
    final owner = link['owner'] as String;
    if (owner == client.userID) {
      throw UserActionError(contactLinkError('invalid_user'));
    }
    // Save only after the explicit confirmation; reopening can resume after any lost reply.
    await client.database.storeAccountData(pendingKey, {'token': token});
    if (link['accepted'] != true) {
      link = await request({'action': 'claim', 'token': token});
      String? roomId = link['room_id'] as String?;
      final existing = client.getRoomById(roomId ?? '');
      if (existing?.membership == Membership.invite) {
        await existing!.addToDirectChat(owner);
        await existing.join();
      } else if (existing?.membership != Membership.join) {
        roomId = await _createRoom(owner, link['id'] as String);
      }
      link = await request({
        'action': 'accept',
        'token': token,
        'room_id': roomId,
      });
    }
    await contacts.refresh();
    final roomId = link['room_id'] as String;
    final invited = client.getRoomById(roomId);
    if (invited?.membership == Membership.invite) await invited!.join();
    final room = await probe.room(roomId);
    // This flow sends before opening the timeline, which normally loads the full state.
    await room.postLoad();
    await room.addToDirectChat(owner);
    final until = DateTime.now().add(const Duration(seconds: 30));
    while (room.directChatMatrixID != owner) {
      if (DateTime.now().isAfter(until)) {
        throw TimeoutException('Direct chat sync timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (link['event_id'] == null) {
      final body = <String, dynamic>{'action': 'greet', 'id': link['id']};
      if (link['prepared'] != true) {
        await authorizedDevices(room).timeout(const Duration(seconds: 8));
        await client.encryption!.keyManager.clearOrUseOutboundGroupSession(
          room.id,
          wipe: true,
        );
        body['audience'] = ScheduledMessages(
          client,
          contacts.url,
        ).audience(room);
        body['payload'] = await client.encryption!.encryptGroupMessagePayload(
          room.id,
          {'msgtype': MessageTypes.Text, 'body': 'Привет'},
        );
      }
      final sent = await request(body);
      if (sent['event_id'] is! String ||
          !(sent['event_id'] as String).startsWith(r'$')) {
        throw const FormatException('Greeting not confirmed');
      }
    }
    await client.database.storeAccountData(pendingKey, {});
    return room;
  }

  Future<String> _createRoom(String owner, String invitationId) async {
    // A stable alias recovers a committed createRoom whose HTTP reply was lost.
    final alias = 'voicechat-contact-$invitationId';
    try {
      return await client.createRoom(
        roomAliasName: alias,
        isDirect: true,
        preset: CreateRoomPreset.privateChat,
        invite: [owner],
        initialState: [
          StateEvent(
            type: EventTypes.Encryption,
            stateKey: '',
            content: {'algorithm': 'm.megolm.v1.aes-sha2'},
          ),
          StateEvent(
            type: 'dev.voicechat.kind',
            stateKey: '',
            content: {'kind': 'direct', 'owner': client.userID, 'peer': owner},
          ),
          StateEvent(
            type: 'm.room.history_visibility',
            stateKey: '',
            content: {'history_visibility': 'invited'},
          ),
        ],
      );
    } catch (error, stack) {
      try {
        final serverName = client.userID!.substring(
          client.userID!.indexOf(':') + 1,
        );
        final id = (await client.getRoomIdByAlias(
          '#$alias:$serverName',
        )).roomId;
        if (id == null) Error.throwWithStackTrace(error, stack);
        return id;
      } catch (_) {
        Error.throwWithStackTrace(error, stack);
      }
    }
  }
}
