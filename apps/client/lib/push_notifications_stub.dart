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
