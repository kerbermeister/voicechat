import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'transport.dart';
import 'user_action_error.dart';
import 'group_invitations.dart';

final _services = Expando<ContactService>();

class ContactRequest {
  final String id, sender, recipient, roomId, state;
  ContactRequest.fromJson(Map<String, dynamic> value)
    : id = value['id'] as String,
      sender = value['sender'] as String,
      recipient = value['recipient'] as String,
      roomId = value['room_id'] as String,
      state = value['state'] as String {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        !sender.startsWith('@') ||
        !recipient.startsWith('@') ||
        sender == recipient ||
        !roomId.startsWith('!') ||
        !['pending', 'accepted', 'declined', 'cancelled'].contains(state)) {
      throw const FormatException('Invalid contact request');
    }
  }
  String peer(String own) => sender == own ? recipient : sender;
}

class ContactService extends ChangeNotifier {
  final Client client;
  final String url;
  bool allowDirect = true;
  bool available = false;
  bool _closed = false;
  List<ContactRequest> requests = [];
  List<GroupInvitation> groups = [];
  Timer? _timer;
  StreamSubscription<dynamic>? _sync;
  StreamSubscription<dynamic>? _members;
  final _groupEvents = <String, ({String roomId, StrippedStateEvent state})>{};
  Future<void>? _refreshing;
  Future<void> _write = Future.value();
  static const _storage = 'dev.voicechat.local.contacts';
  static const _groupStorage = 'dev.voicechat.local.groupInvitations';
  ContactService(this.client, this.url) {
    _services[client] = this;
  }
  static ContactService? of(Client client) => _services[client];
  bool acceptsRoom(String roomId, String peer) => requests.any(
    (r) =>
        r.roomId == roomId &&
        r.peer(client.userID!) == peer &&
        r.state == 'accepted',
  );
  Set<String> get acceptedUsers => {
    for (final r in requests)
      if (r.state == 'accepted') r.peer(client.userID!),
  };
  Future<GetPresenceResponse> presence(String userId) async {
    if (!acceptedUsers.contains(userId)) {
      throw UserActionError('Контакт не принят.');
    }
    final query = Uri(queryParameters: {'user_id': userId}).query;
    final data = await _api('/presence?$query');
    if (!['online', 'offline', 'unavailable'].contains(data['presence'])) {
      throw const FormatException('Invalid contact presence');
    }
    return GetPresenceResponse.fromJson(data);
  }

  Set<String> get hiddenRooms => {
    for (final r in requests)
      if (r.state != 'accepted') r.roomId,
  };
  int get incomingCount => requests
      .where((r) => r.recipient == client.userID && r.state == 'pending')
      .length;
  void _adopt(Map<String, dynamic> data) {
    if (data['allow_direct'] is! bool ||
        data['requests'] is! List ||
        (data['requests'] as List).length > 5000) {
      throw const FormatException('Invalid contacts');
    }
    final parsed = (data['requests'] as List)
        .map(
          (v) => ContactRequest.fromJson(Map<String, dynamic>.from(v as Map)),
        )
        .toList();
    if (parsed.any(
      (r) => r.sender != client.userID && r.recipient != client.userID,
    )) {
      throw const FormatException('Unrelated contact');
    }
    allowDirect = data['allow_direct'] as bool;
    requests = parsed;
  }

  Future<void> open() async {
    final saved = await client.database.getAccountData();
    final cache = saved[_storage]?.content;
    if (cache != null) _adopt(cache);
    final items = saved[_groupStorage]?.content['items'];
    if (items is List && items.length <= 5000) {
      groups = items
          .map(
            (v) =>
                GroupInvitation.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList();
    }
    await refresh();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => refresh());
    _sync = client.onSync.stream.listen((_) => unawaited(refresh()));
    _members = client.onRoomState.stream.listen((update) {
      if (update.state.type != EventTypes.RoomMember) return;
      _groupEvents['${update.roomId}\u0000${update.state.stateKey}'] = update;
      unawaited(refresh());
    });
  }

  Future<Map<String, dynamic>> _api(
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final endpoint = secureEndpoint('$url$path');
    final headers = {
      'Authorization': 'Bearer ${client.accessToken}',
      if (body != null) 'Content-Type': 'application/json',
    };
    final response =
        await (body == null
                ? client.httpClient.get(endpoint, headers: headers)
                : client.httpClient.post(
                    endpoint,
                    headers: headers,
                    body: jsonEncode(body),
                  ))
            .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200 || response.bodyBytes.length > 2097152) {
      throw UserActionError(
        'Сервис контактов недоступен или действие запрещено. Повторите после восстановления связи.',
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  Future<void> _refresh() async {
    if (_closed) return;
    try {
      final updates = Map.of(_groupEvents);
      final observed = groupInvitations(
        client,
        groups,
        updates: updates.values,
      );
      final items = observed.map((v) => v.toJson()).toList();
      if (jsonEncode(items) !=
          jsonEncode(groups.map((v) => v.toJson()).toList())) {
        await (_write = client.database.storeAccountData(_groupStorage, {
          'items': items,
        }));
        groups = observed;
      }
      for (final entry in updates.entries) {
        if (_groupEvents[entry.key] == entry.value) {
          _groupEvents.remove(entry.key);
        }
      }
      final data = await _api('/contacts');
      if (_closed) return;
      final previous = {'allow_direct': allowDirect, 'requests': requests};
      _adopt(data);
      try {
        await (_write = client.database.storeAccountData(_storage, data));
      } catch (_) {
        allowDirect = previous['allow_direct'] as bool;
        requests = previous['requests'] as List<ContactRequest>;
        rethrow;
      }
      if (_closed) return;
      available = true;
      for (final request in requests.where(
        (r) => r.state == 'accepted' && r.recipient == client.userID,
      )) {
        final room = client.getRoomById(request.roomId);
        if (room?.membership == Membership.invite) {
          try {
            // Consent names this private room; old reinvites can omit is_direct.
            await room!.addToDirectChat(request.peer(client.userID!));
            await room.join();
          } catch (_) {
            /* Retry on next sync; consent remains durable. */
          }
        }
      }
    } catch (_) {
      available = false;
    }
    if (!_closed) notifyListeners();
  }

  Future<ContactRequest> request(String recipient, String room) async {
    final result = ContactRequest.fromJson(
      await _api('/contacts', {
        'action': 'request',
        'recipient': recipient,
        'room_id': room,
      }),
    );
    await _refreshing;
    await refresh();
    return result;
  }

  Future<bool> policyFor(String user) async =>
      (await _api(
        '/contact-policy?user_id=${Uri.encodeQueryComponent(user)}',
      ))['allow_direct'] ==
      true;
  Future<void> decide(ContactRequest request, String action) async {
    await _api('/contacts', {'action': action, 'id': request.id});
    await _refreshing;
    await refresh();
    if (action == 'decline' || action == 'cancel') {
      final room = client.getRoomById(request.roomId);
      if (room != null &&
          [Membership.invite, Membership.join].contains(room.membership)) {
        await room.leave();
      }
    }
  }

  Future<void> setAllowDirect(bool value) async {
    await _api('/contacts', {'action': 'policy', 'allow_direct': value});
    await _refreshing;
    await refresh();
    if (!available || allowDirect != value) {
      throw UserActionError(
        'Не удалось подтвердить сохранение настройки. Повторите после восстановления связи.',
      );
    }
  }

  Future<void> close() async {
    _closed = true;
    if (identical(_services[client], this)) _services[client] = null;
    _timer?.cancel();
    await _sync?.cancel();
    await _members?.cancel();
    try {
      await _write;
    } finally {
      dispose();
    }
  }
}
