import 'package:http/http.dart' as http;
import 'app_update.dart';

Future<void> downloadUpdate(
  http.Client client,
  String origin,
  AppUpdate update,
  String path,
  void Function(int) progress,
  bool Function() cancelled,
) async {
  throw UnsupportedError('Android only');
}
