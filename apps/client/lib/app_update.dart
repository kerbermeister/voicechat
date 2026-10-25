import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

const maxApkBytes = 300 * 1024 * 1024;
const updateOrigin = String.fromEnvironment('MATRIX_URL');

class AppUpdate {
  final String applicationId, versionName, sha256, notes, apkPath;
  final int versionCode, minSdk, sizeBytes;
  AppUpdate._(Map<String, dynamic> data)
    : applicationId = data['applicationId'] as String,
      versionName = data['versionName'] as String,
      versionCode = data['versionCode'] as int,
      minSdk = data['minSdk'] as int,
      sizeBytes = data['sizeBytes'] as int,
      sha256 = data['sha256'] as String,
      notes = data['notes'] as String,
      apkPath = data['apkPath'] as String;

  factory AppUpdate.parse(String source, String package) {
    final dynamic value;
    try {
      value = jsonDecode(source);
    } on FormatException {
      throw const FormatException(
        'Сервер вернул неверное описание обновления.',
      );
    }
    if (value is! Map<String, dynamic> ||
        value.values.any((v) => v is Map || v is List)) {
      throw const FormatException('Неверное описание обновления.');
    }
    // This schema is flat. Decode escaped key names before detecting duplicates.
    final tokens = RegExp(
      r'"(?:[^"\\]|\\.)*"|[{}:,]',
    ).allMatches(source).map((m) => m[0]!).toList();
    final keys = [
      for (var i = 0; i + 1 < tokens.length; i++)
        if (tokens[i].startsWith('"') && tokens[i + 1] == ':')
          jsonDecode(tokens[i]),
    ];
    if (keys.toSet().length != keys.length ||
        value['schema'] != 1 ||
        value['schema'] is! int ||
        value['applicationId'] != package ||
        value['versionName'] is! String ||
        !RegExp(
          r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
        ).hasMatch(value['versionName'] as String) ||
        value['versionCode'] is! int ||
        (value['versionCode'] as int) < 1 ||
        (value['versionCode'] as int) > 2100000000 ||
        value['minSdk'] is! int ||
        (value['minSdk'] as int) < 1 ||
        (value['minSdk'] as int) > 1000 ||
        value['sizeBytes'] is! int ||
        (value['sizeBytes'] as int) < 1 ||
        (value['sizeBytes'] as int) > maxApkBytes ||
        value['sha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['sha256'] as String) ||
        value['notes'] is! String ||
        (value['notes'] as String).trim().isEmpty ||
        (value['notes'] as String).length > 4000 ||
        value['apkPath'] !=
            '/updates/android/${value['versionCode']}/voicechat.apk') {
      throw const FormatException('Неверное описание обновления.');
    }
    return AppUpdate._(value);
  }

  Map<String, Object> get installArguments => {
    'applicationId': applicationId,
    'versionName': versionName,
    'versionCode': versionCode,
    'minSdk': minSdk,
    'sizeBytes': sizeBytes,
    'sha256': sha256,
  };
}

Uri updateUrl(String origin, String path) {
  final uri = Uri.parse(origin);
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !['', '/'].contains(uri.path)) {
    throw const FormatException('Сервер обновлений не настроен.');
  }
  return uri.replace(path: path);
}

Future<AppUpdate> checkAppUpdate(
  http.Client client,
  String origin,
  String package,
) async {
  final request = http.Request(
    'GET',
    updateUrl(origin, '/updates/android/latest.json'),
  )..followRedirects = false;
  return (() async {
    final response = await client.send(request);
    if (response.statusCode != 200) {
      throw const FormatException(
        'Канал обновлений недоступен. Повторите позже.',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > 65536) {
        throw const FormatException('Описание обновления слишком большое.');
      }
      bytes.addAll(chunk);
    }
    final String source;
    try {
      source = utf8.decode(bytes);
    } on FormatException {
      throw const FormatException(
        'Сервер вернул неверную кодировку описания обновления.',
      );
    }
    return AppUpdate.parse(source, package);
  })().timeout(const Duration(seconds: 15));
}
