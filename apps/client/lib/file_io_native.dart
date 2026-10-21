import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'chunked_file.dart';

const _channel = MethodChannel('voicechat/save');
Future<Directory> _recordingDirectory() async =>
    Directory((await _channel.invokeMethod<String>('cacheDirectory'))!);
Future<void> cleanupRecordings() async {
  await for (final entity in (await _recordingDirectory()).list(
    followLinks: false,
  )) {
    if (entity is File &&
        RegExp(r'^REC[0-9]+\.mp4$').hasMatch(entity.uri.pathSegments.last)) {
      await entity.delete();
    }
  }
}

Future<void> deleteRecording(String path) async {
  final root = await (await _recordingDirectory()).resolveSymbolicLinks();
  final file = File(path);
  if (!await file.exists()) return;
  final resolved = await file.resolveSymbolicLinks();
  if (!resolved.startsWith('$root/')) {
    throw StateError('Recording outside private cache');
  }
  await file.delete();
}

Future<void> saveFile(
  ChunkedFile file,
  void Function(double) progress,
  bool Function() cancelled,
) async {
  final id = await _channel.invokeMethod<String>('begin', {
    'name': file.name,
    'mime': file.mime,
  });
  if (id == null) return;
  var success = false;
  try {
    var written = 0;
    await for (final bytes in file.range(0, file.size)) {
      if (cancelled()) throw StateError('Cancelled');
      await _channel.invokeMethod<void>('write', {'id': id, 'bytes': bytes});
      written += bytes.length;
      progress(written / file.size);
    }
    success = true;
  } finally {
    await _channel.invokeMethod<void>('finish', {'id': id, 'success': success});
    file.clear();
  }
}

Future<({String url, Future<void> Function() close})> videoSource(
  ChunkedFile file,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final random = Random.secure();
  final nonce = List.generate(
    32,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  server.listen((request) async {
    final response = request.response;
    try {
      if (request.uri.path != '/$nonce' ||
          !['GET', 'HEAD'].contains(request.method)) {
        response.statusCode = 404;
        return;
      }
      var start = 0, end = file.size;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
        if (match == null) {
          response.statusCode = 416;
          return;
        }
        start = int.parse(match[1]!);
        if (match[2]!.isNotEmpty) {
          end = (int.parse(match[2]!) + 1).clamp(0, file.size);
        }
        if (start >= end || start >= file.size) {
          response.statusCode = 416;
          return;
        }
        response.statusCode = 206;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${end - 1}/${file.size}',
        );
      }
      response.headers.set(HttpHeaders.contentTypeHeader, file.mime);
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.contentLength = end - start;
      if (request.method == 'GET') {
        await response.addStream(file.range(start, end));
      }
    } catch (_) {
      response.statusCode = 500;
    } finally {
      await response.close();
    }
  });
  return (
    url: 'http://127.0.0.1:${server.port}/$nonce',
    close: () async {
      await server.close(force: true);
      file.clear();
    },
  );
}
