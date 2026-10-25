import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
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
  final file = File(path);
  var complete = false;
  var expired = false;
  final timer = Timer(const Duration(minutes: 15), () {
    expired = true;
    client.close();
  });
  try {
    final request = http.Request('GET', updateUrl(origin, update.apkPath))
      ..followRedirects = false
      ..headers['Accept-Encoding'] = 'identity';
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200 ||
        (response.contentLength != null &&
            response.contentLength != update.sizeBytes)) {
      throw const FormatException('Не удалось загрузить полный APK.');
    }
    final output = await file.open(mode: FileMode.write);
    try {
      var received = 0;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        if (cancelled()) throw StateError('Загрузка отменена.');
        received += chunk.length;
        if (received > update.sizeBytes) {
          throw const FormatException('Неверный размер APK.');
        }
        await output.writeFrom(chunk);
        progress(received);
      }
      if (received != update.sizeBytes || cancelled()) {
        throw const FormatException('Загрузка не завершена.');
      }
      await output.flush();
    } finally {
      await output.close();
    }
    if ((await sha256.bind(file.openRead()).first).toString() !=
            update.sha256 ||
        cancelled() ||
        expired) {
      throw const FormatException('Проверка целостности APK не пройдена.');
    }
    complete = true;
  } finally {
    timer.cancel();
    if (!complete && await file.exists()) await file.delete();
  }
}
