import 'package:matrix/matrix.dart';

String deviceAddedType(String deviceId) =>
    'dev.voicechat.device.added.${Uri.encodeComponent(deviceId)}';

DateTime? deviceAddedAt(Client client, String deviceId) {
  final value =
      client.accountData[deviceAddedType(deviceId)]?.content['added_at'];
  return value is int &&
          value > 0 &&
          value <=
              DateTime.now()
                  .add(const Duration(minutes: 5))
                  .millisecondsSinceEpoch
      ? DateTime.fromMillisecondsSinceEpoch(value).toLocal()
      : null;
}

/// Written only after a new login/registration, never when resuming an old device.
Future<void> recordDeviceAdded(Client client, DateTime addedAt) async {
  try {
    final device = client.deviceID, user = client.userID;
    if (device == null || user == null) return;
    final type = deviceAddedType(device);
    if (client.accountData[type]?.content['added_at'] is int) return;
    final content = <String, Object?>{
      'added_at': addedAt.toUtc().millisecondsSinceEpoch,
    };
    await client.setAccountData(user, type, content);
    client.accountData[type] = BasicEvent(type: type, content: content);
  } catch (_) {
    // Optional display metadata cannot invalidate a successful authenticated login.
    // Missing historical metadata is shown as unknown, not inferred from last_seen.
  }
}
