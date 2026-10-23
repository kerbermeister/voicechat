import 'package:matrix/matrix.dart' as mx;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'call_probe.dart';
import 'direct_call.dart';
import 'matrix_probe.dart';
import 'user_action_error.dart';
import 'voice_call.dart';

/// Формирует привязку только текущего подключённого звонка.
/// Сервер повторно проверяет membership, ключи и взаимное подтверждение устройств.
Future<Map<String, dynamic>> screenBindingRequest(
  VoiceCall call, {
  ScreenCallParties? parties,
}) async {
  if (call.isClosed) throw UserActionError('Звонок уже завершён.');
  final body = <String, dynamic>{
    'protocol_version': 1,
    'room_id': call.chat.id,
    'call_session': call.session,
  };
  if (call case CallProbe group) {
    final lease = group.screenBindingLease;
    if (lease == null ||
        group.media?.connectionState != lk.ConnectionState.connected) {
      throw UserActionError('Дождитесь подключения к звонку.');
    }
    return {...body, 'transport': 'group', 'call_lease_id': lease};
  }
  if (call case DirectCall direct) {
    if (direct.call.state != mx.CallState.kConnected) {
      throw UserActionError('Дождитесь ответа собеседника.');
    }
    // party_id — случайный VoIP session ID. Устройство выбранной стороны
    // подтверждает sender_key зашифрованного invite/answer, а не invitee_device_id.
    final peer =
        selectedScreenPeer(direct.call.remoteUserId, parties?.curve(direct), [
          for (final device in await authorizedDevices(call.chat))
            if (device.deviceId != null)
              (
                user: device.userId,
                device: device.deviceId!,
                curve: device.curve25519Key,
              ),
        ]);
    if (call.isClosed) throw UserActionError('Звонок уже завершён.');
    return {...body, 'transport': 'direct', 'peer': peer};
  }
  throw UserActionError('Этот тип звонка не поддерживает демонстрацию.');
}

/// Sender key выбранного call event должен совпасть с доверенным device.
Map<String, String> selectedScreenPeer(
  String? user,
  String? curve,
  List<({String user, String device, String? curve})> trusted,
) {
  final selected = trusted.where(
    (entry) => entry.user == user && entry.curve == curve && curve != null,
  );
  if (user == null || selected.length != 1) {
    throw UserActionError('Не удалось подтвердить устройство собеседника.');
  }
  return {'user_id': user, 'device_id': selected.single.device};
}

/// Ограниченная память текущих зашифрованных VoIP-сигналов, без SDP/медиаключей.
class ScreenCallParties {
  final _signals =
      <
        ({String room, String session, String party}),
        ({String user, String curve})
      >{};
  void observe(List<mx.BasicEventWithSender> events) {
    for (final event in events) {
      if (!{
        mx.EventTypes.CallInvite,
        mx.EventTypes.CallAnswer,
      }.contains(event.type)) {
        continue;
      }
      if (event is mx.Event &&
          event.originalSource?.type != mx.EventTypes.Encrypted) {
        continue;
      }
      final room = event is mx.Event ? event.room.id : event.content['room_id'];
      final encrypted = event is mx.Event
          ? event.originalSource?.content
          : event is mx.ToDeviceEvent
          ? event.encryptedContent
          : null;
      final curve = encrypted?['sender_key'],
          session = event.content['call_id'],
          party = event.content['party_id'];
      if (room is! String ||
          curve is! String ||
          session is! String ||
          party is! String ||
          curve.length != 43 ||
          session.length > 128 ||
          party.length > 128) {
        continue;
      }
      _signals.putIfAbsent((
        room: room,
        session: session,
        party: party,
      ), () => (user: event.senderId, curve: curve));
      if (_signals.length > 128) {
        _signals.remove(_signals.keys.first);
      }
    }
  }

  String? curve(DirectCall call) {
    final party = call.call.remotePartyId;
    if (party == null) return null;
    final signal =
        _signals[(room: call.chat.id, session: call.session, party: party)];
    return signal?.user == call.call.remoteUserId ? signal?.curve : null;
  }
}
