import 'package:matrix/matrix.dart' as mx;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'call_probe.dart';
import 'direct_call.dart';
import 'matrix_probe.dart';
import 'user_action_error.dart';
import 'voice_call.dart';

/// Формирует привязку только текущего подключённого звонка.
/// Сервер повторно проверяет membership, ключи и взаимное подтверждение устройств.
Future<Map<String, dynamic>> screenBindingRequest(VoiceCall call) async {
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
    // party_id в этом клиенте равен deviceID. remoteDeviceId может обозначать
    // адресата приглашения и не доказывает, какое устройство ответило.
    final peer = selectedScreenPeer(
      direct.call.remoteUserId,
      direct.call.remotePartyId,
      [
        for (final device in await authorizedDevices(call.chat))
          if (device.deviceId != null)
            (user: device.userId, device: device.deviceId!),
      ],
    );
    if (call.isClosed) throw UserActionError('Звонок уже завершён.');
    return {...body, 'transport': 'direct', 'peer': peer};
  }
  throw UserActionError('Этот тип звонка не поддерживает демонстрацию.');
}

/// party_id — кандидат, а не полномочие: он должен совпасть с доверенным device.
Map<String, String> selectedScreenPeer(
  String? user,
  String? party,
  List<({String user, String device})> trusted,
) {
  if (user == null ||
      party == null ||
      !trusted.any((entry) => entry.user == user && entry.device == party)) {
    throw UserActionError('Не удалось подтвердить устройство собеседника.');
  }
  return {'user_id': user, 'device_id': party};
}
