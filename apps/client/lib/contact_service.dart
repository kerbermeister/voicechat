import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'transport.dart';
import 'user_action_error.dart';

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
  Timer? _timer;
  StreamSubscription<dynamic>? _sync;
  Future<void>? _refreshing;
  Future<void> _write = Future.value();
  static const _storage = 'dev.voicechat.local.contacts';
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
    final cache = (await client.database.getAccountData())[_storage]?.content;
    if (cache != null) _adopt(cache);
    await refresh();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => refresh());
    _sync = client.onSync.stream.listen((_) => unawaited(refresh()));
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
        if (room?.membership == Membership.invite &&
            room
                    ?.getState(EventTypes.RoomMember, client.userID!)
                    ?.content['is_direct'] ==
                true) {
          try {
            await room!.join();
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
  }

  Future<void> close() async {
    _closed = true;
    if (identical(_services[client], this)) _services[client] = null;
    _timer?.cancel();
    await _sync?.cancel();
    try {
      await _write;
    } finally {
      dispose();
    }
  }
}
