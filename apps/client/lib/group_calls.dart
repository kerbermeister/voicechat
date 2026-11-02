import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'personal_room.dart';
import 'route_transport.dart';
import 'transport.dart';
import 'user_action_error.dart';

class OngoingGroupCall {
  final Room room;
  final String session;
  final bool video;
  final int participants;
  OngoingGroupCall(this.room, this.session, this.video, this.participants);
}

/// The server's live leases, rather than an old invitation or local storage,
/// determine whether a group call can be rejoined after reopening the client.
class GroupCalls {
  final Client client;
  final String tokenUrl;
  final void Function() changed;
  final http.Client _network;
  Room? _room;
  OngoingGroupCall? current;
  bool _closed = false, _loading = false;
  Timer? _stale;
  GroupCalls(this.client, this.tokenUrl, this.changed, {http.Client? network})
    : _network =
          network ??
          routeTransportOf(client.httpClient)?.fork() ??
          http.Client();

  bool _eligible(Room room) =>
      !room.isDirectChat &&
      !isPersonalRoom(room) &&
      room.encrypted &&
      room.membership == Membership.join;

  void watch(Room? room) {
    if (_closed) return;
    final next = room != null && _eligible(room) ? room : null;
    if (_room == next) return;
    _room = next;
    current = null;
    _stale?.cancel();
    unawaited(refresh());
  }

  Future<OngoingGroupCall?> find(Room room) async {
    if (_closed || !_eligible(room)) return null;
    final response = await _network
        .post(
          secureEndpoint('$tokenUrl/call/active'),
          headers: {
            'Authorization': 'Bearer ${client.accessToken}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'room_id': room.id}),
        )
        .timeout(const Duration(seconds: 5));
    if (_closed || !_eligible(room)) return null;
    // Compatibility with servers before call discovery; ordinary calling remains available.
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw UserActionError(
        'Не удалось проверить текущий звонок группы. Повторите попытку.',
      );
    }
    if (response.bodyBytes.length > 8192) {
      throw const FormatException('Oversized call discovery');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is! Map ||
        data['calls'] is! List ||
        (data['calls'] as List).length > 10) {
      throw const FormatException('Invalid call discovery');
    }
    final calls = <OngoingGroupCall>[];
    for (final call in data['calls'] as List) {
      if (call is! Map ||
          call['session'] is! String ||
          (call['session'] as String).isEmpty ||
          (call['session'] as String).length > 64 ||
          call['video'] is! bool ||
          call['participants'] is! int ||
          call['participants'] < 1 ||
          call['participants'] > 10) {
        throw const FormatException('Invalid active call');
      }
      calls.add(
        OngoingGroupCall(
          room,
          call['session'],
          call['video'],
          call['participants'],
        ),
      );
    }
    return calls.firstOrNull;
  }

  Future<void> refresh() async {
    final room = _room;
    if (_closed || room == null) return;
    if (!_eligible(room)) {
      final hadCurrent = current != null;
      current = null;
      _stale?.cancel();
      if (hadCurrent) changed();
      return;
    }
    if (_loading) return;
    _loading = true;
    try {
      final next = await find(room);
      if (_closed || _room != room) return;
      current = _eligible(room) ? next : null;
      _stale?.cancel();
      if (next != null) {
        _stale = Timer(const Duration(seconds: 30), () {
          current = null;
          changed();
        });
      }
    } catch (_) {
      // A brief outage need not hide the banner; the last confirmation expires.
    } finally {
      _loading = false;
      if (!_closed) changed();
      if (!_closed && _room != room) unawaited(refresh());
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _stale?.cancel();
    current = null;
    _network.close();
  }
}
