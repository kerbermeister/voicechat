import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/notification_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in ['android', 'macos', 'web']) {
    test(
      '$platform update enables an old opt-out once, then respects manual off',
      () async {
        final key = '${platform}Notifications:alice';
        SharedPreferences.setMockInitialValues({key: false});
        final prefs = await SharedPreferences.getInstance();
        expect(await applyNotificationDefault(prefs, key), true);
        expect(prefs.getBool(key), true);
        await prefs.setBool(key, false);
        expect(await applyNotificationDefault(prefs, key), false);
        expect(
          await applyNotificationDefault(prefs, '${platform}Notifications:bob'),
          true,
        );
        expect(prefs.getBool(key), false);
      },
    );
  }
}
