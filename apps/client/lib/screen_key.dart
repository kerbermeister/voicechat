import 'dart:convert';
import 'dart:typed_data';
import 'screen_state.dart';

/// Matrix уже расшифровал envelope; здесь связываем его с точным допуском экрана.
Uint8List? screenKey(
  Map<String, dynamic> data, {
  required ScreenSnapshot snapshot,
  required String room,
  required String session,
  required String sender,
  required String device,
  required String curve,
  required String ed,
  required int now,
}) {
  final owner = '$sender/$device';
  if (snapshot.state != 'active' ||
      snapshot.owner != owner ||
      !snapshot.roster.any(
        (r) => r.identity == owner && r.curve == curve && r.ed == ed,
      ) ||
      data['protocol_version'] is! int ||
      data['protocol_version'] != 1 ||
      data['room_id'] != room ||
      data['call_session'] != session ||
      data['binding_id'] != snapshot.binding ||
      data['screen_generation'] != snapshot.generation ||
      data['revision'] != snapshot.revision ||
      data['roster_version'] != snapshot.rosterVersion ||
      data['sender_identity'] != owner ||
      data['sender_device'] != device) {
    return null;
  }
  final expires = data['expires_at'], raw = data['key'];
  if (expires is! int ||
      expires <= now ||
      expires > now + 60000 ||
      raw is! String ||
      raw.length != 44) {
    return null;
  }
  try {
    final key = base64Decode(raw);
    return key.length == 32 ? Uint8List.fromList(key) : null;
  } on FormatException {
    return null;
  }
}
