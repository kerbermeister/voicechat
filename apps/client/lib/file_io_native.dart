import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'chunked_file.dart';
import 'picked_file.dart';
import 'file_save_result.dart';

Future<FileSaveResult> saveTextFile(String name, String text) async {
  final id = await _channel.invokeMethod<String>('begin', {
    'name': name,
    'mime': 'text/plain',
  });
  if (id == null) return FileSaveResult.cancelled;
  var success = false;
  try {
    await _channel.invokeMethod<void>('write', {
      'id': id,
      'bytes': Uint8List.fromList(utf8.encode(text)),
    });
    success = true;
  } finally {
    await _channel.invokeMethod<void>('finish', {'id': id, 'success': success});
  }
  return FileSaveResult.saved;
}

const _channel = MethodChannel('voicechat/save');
Future<Directory> _recordingDirectory() async =>
    Directory((await _channel.invokeMethod<String>('cacheDirectory'))!);
Future<void> cleanupRecordings() async {
  await for (final entity in (await _recordingDirectory()).list(
    followLinks: false,
  )) {
    if (entity is File &&
        RegExp(
          Platform.isMacOS ? r'^REC[0-9]+\.(mp4|mov)$' : r'^REC[0-9]+\.mp4$',
        ).hasMatch(entity.uri.pathSegments.last)) {
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
  try {
    await saveStreamFile(
      file.name,
      file.mime,
      file.size,
      file.range,
      progress,
      cancelled,
    );
  } finally {
    file.clear();
  }
}

Future<FileSaveResult> saveStreamFile(
  String name,
  String mime,
  int size,
  Stream<Uint8List> Function(int, int) range,
  void Function(double) progress,
  bool Function() cancelled,
) async {
  final id = await _channel.invokeMethod<String>('begin', {
    'name': name,
    'mime': mime,
  });
  if (id == null) return FileSaveResult.cancelled;
  var success = false;
  try {
    var written = 0;
    await for (final bytes in range(0, size)) {
      if (cancelled()) throw StateError('Cancelled');
      await _channel.invokeMethod<void>('write', {'id': id, 'bytes': bytes});
      written += bytes.length;
      progress(size == 0 ? 1 : written / size);
    }
    if (cancelled() || written != size) throw StateError('Incomplete or cancelled save');
    success = true;
  } finally {
    await _channel.invokeMethod<void>('finish', {'id': id, 'success': success});
  }
  return FileSaveResult.saved;
}

Future<({String url, Future<void> Function() close})> videoSource(
  ChunkedFile file,
) => _videoSource(file.size, file.mime, file.range, file.clear);

Future<({String url, Future<void> Function() close})> draftVideoSource(
  PickedFile file,
) => _videoSource(file.size, file.mime, file.range, () {});

Future<({String url, Future<void> Function() close})> _videoSource(
  int size,
  String mime,
  Stream<List<int>> Function(int, int) rangeBytes,
  void Function() clear,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final random = Random.secure();
  final nonce = List.generate(
    32,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  server.listen((request) async {
    final response = request.response;
    // An aborted response reports errors through done as well as addStream/close.
    unawaited(
      response.done.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
    try {
      if (request.uri.path != '/$nonce' ||
          !['GET', 'HEAD'].contains(request.method)) {
        response.statusCode = 404;
        return;
      }
      var start = 0, end = size;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
        if (match == null) {
          response.statusCode = 416;
          return;
        }
        start = int.parse(match[1]!);
        if (match[2]!.isNotEmpty) {
          end = (int.parse(match[2]!) + 1).clamp(0, size);
        }
        if (start >= end || start >= size) {
          response.statusCode = 416;
          return;
        }
        response.statusCode = 206;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${end - 1}/$size',
        );
      }
      response.headers.set(HttpHeaders.contentTypeHeader, mime);
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.contentLength = end - start;
      if (request.method == 'GET') {
        await response.addStream(rangeBytes(start, end));
      }
    } catch (_) {
      try {
        response.statusCode = 500;
      } catch (_) {
        /* A seeking/closing player may already have disconnected. */
      }
    } finally {
      try {
        await response.close();
      } catch (_) {
        /* The cancelled range no longer has a response consumer. */
      }
    }
  });
  return (
    url: 'http://127.0.0.1:${server.port}/$nonce',
    close: () async {
      await server.close(force: true);
      clear();
    },
  );
}
