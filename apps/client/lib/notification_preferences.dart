import 'package:shared_preferences/shared_preferences.dart';

/// Build 40 enables notifications once on every updated installation/account.
/// A later manual opt-out remains effective across restarts and future updates.
Future<bool> applyNotificationDefault(
  SharedPreferences prefs,
  String key,
) async {
  final migration = 'notificationsDefault40:$key';
  if (prefs.getBool(migration) != true) {
    await prefs.setBool(key, true);
    await prefs.setBool(migration, true);
  }
  return prefs.getBool(key) ?? true;
}
