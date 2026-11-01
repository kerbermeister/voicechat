import 'package:http/http.dart' as http;

Future<String> enablePushNotifications(
  String url,
  String token, {
  http.Client Function()? createClient,
}) async => 'Уведомления доступны в web-приложении.';
Future<String> disablePushNotifications(
  String url,
  String token, {
  http.Client Function()? createClient,
}) async => '';

Future<bool> pushNotificationsEnabled() async => false;

Future<bool> pushNotificationsPermissionGranted() async => false;
