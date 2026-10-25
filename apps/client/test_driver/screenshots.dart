import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(
  onScreenshot: (name, bytes, [args]) async {
    final directory = Directory(
      Platform.environment['VOICECHAT_SCREENSHOTS'] ??
          '../../.prototype/android-ui',
    );
    await directory.create(recursive: true);
    await File('${directory.path}/$name.png').writeAsBytes(bytes);
    return bytes.isNotEmpty;
  },
);
