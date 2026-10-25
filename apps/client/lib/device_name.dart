import 'package:matrix/matrix.dart';
import 'device_name_native.dart'
    if (dart.library.js_interop) 'device_name_web.dart'
    as platform;
export 'device_name_native.dart'
    if (dart.library.js_interop) 'device_name_web.dart'
    show currentDeviceName;

const _genericNames = {
  null,
  '',
  'VoiceChat',
  'VoiceChat · браузер',
  'VoiceChat · Web',
  'VoiceChat · Android',
};

String accountDeviceName(Device device) =>
    _genericNames.contains(device.displayName)
    ? 'Устройство · модель не определена'
    : device.displayName!;

Future<void> refreshCurrentDeviceName(Client client) async {
  try {
    final id = client.deviceID;
    if (id == null) return;
    final devices = await client.getDevices().timeout(
      const Duration(seconds: 5),
    );
    final current = devices
        ?.where((device) => device.deviceId == id)
        .firstOrNull;
    // Preserve user-supplied names and never infer another device's model from this browser.
    if (current == null || !_genericNames.contains(current.displayName)) return;
    await client
        .updateDevice(id, displayName: await platform.currentDeviceName())
        .timeout(const Duration(seconds: 5));
  } catch (_) {
    // Optional presentation metadata cannot invalidate an authenticated session.
  }
}
