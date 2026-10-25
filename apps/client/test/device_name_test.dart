import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/device_description.dart';
import 'package:voicechat_probe/device_name.dart';
import 'chat_actions_test.dart' show OutboxDatabase;

class NamingClient extends Client {
  NamingClient() : super('device-name', database: OutboxDatabase());
  @override
  String get deviceID => 'CURRENT';
  List<Device> devices = [];
  final renamed = <String>[];
  bool offline = false;
  @override
  Future<List<Device>?> getDevices() async {
    if (offline) throw StateError('offline');
    return devices;
  }

  @override
  Future<void> updateDevice(String id, {String? displayName}) async {
    renamed.add(id);
    expect(displayName, startsWith('VoiceChat · '));
  }
}

void main() {
  test(
    'Browser descriptions distinguish devices and browsers without inventing hidden models',
    () {
      expect(
        browserDeviceDescription(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 Version/18.3 Mobile/15E148 Safari/604.1',
        ),
        'iPhone · Safari',
      );
      expect(
        browserDeviceDescription(
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36',
        ),
        'Mac · macOS · Chrome',
      );
      expect(
        browserDeviceDescription(
          'Mozilla/5.0 (Macintosh; Intel Mac OS X) Version/18.3 Safari/604.1',
          touchPoints: 5,
        ),
        'iPad · Safari',
      );
      expect(
        browserDeviceDescription(
          'Mozilla/5.0 (Linux; Android 14; Pixel 7 Build/ABC) Chrome/130 Safari/537.36',
        ),
        'Pixel 7 · Android · Chrome',
      );
      expect(
        browserDeviceDescription(
          'Mozilla/5.0 (Linux; Android 10; K) Chrome/130 Safari/537.36',
        ),
        'Android · Chrome',
      );
      expect(
        browserDeviceDescription(
          'Mozilla/5.0 (Windows NT 10.0) Chrome/130 Safari/537.36 Edg/130',
        ),
        'Компьютер · Windows · Edge',
      );
      expect(
        browserDeviceDescription(
          'Mozilla/5.0 (iPhone) FxiOS/130 Mobile Safari/605',
        ),
        'iPhone · Firefox',
      );
      expect(browserDeviceDescription('unknown'), 'Веб-устройство · Браузер');
    },
  );
  test(
    'Only the current generic device is upgraded; custom names and other devices remain intact',
    () async {
      final client = NamingClient();
      client.devices = [
        Device(deviceId: 'CURRENT', displayName: 'VoiceChat'),
        Device(deviceId: 'OTHER', displayName: 'VoiceChat'),
      ];
      await refreshCurrentDeviceName(client);
      expect(client.renamed, ['CURRENT']);
      client.devices = [
        Device(deviceId: 'CURRENT', displayName: 'Мой ноутбук'),
      ];
      await refreshCurrentDeviceName(client);
      expect(client.renamed, ['CURRENT']);
      expect(accountDeviceName(client.devices.single), 'Мой ноутбук');
      expect(
        accountDeviceName(Device(deviceId: 'OLD', displayName: 'VoiceChat')),
        contains('модель не определена'),
      );
      client.offline = true;
      await refreshCurrentDeviceName(client);
      expect(client.renamed, ['CURRENT']);
    },
  );
}
