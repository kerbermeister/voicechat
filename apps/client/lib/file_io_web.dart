import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'chunked_file.dart';
import 'picked_file.dart';
import 'file_save_result.dart';

Future<FileSaveResult> saveTextFile(String name, String text) async {
  final bytes = Uint8List.fromList(utf8.encode(text));
  if (!_supportsSavePicker().toDart) {
    // A tiny local Blob avoids putting the recovery secret through the streaming worker.
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
    );
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = name;
    try {
      web.document.body!.append(anchor);
      anchor.click();
    } finally {
      anchor.remove();
      Timer(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
    }
    // Browsers do not report whether a download was actually saved by the user.
    return FileSaveResult.downloadStarted;
  }
  final id = (await _beginSave(name.toJS).toDart)?.toDart;
  if (id == null) return FileSaveResult.cancelled;
  var success = false;
  try {
    await _write(id.toJS, bytes.toJS).toDart;
    success = true;
  } finally {
    await _finish(id.toJS, success.toJS).toDart;
  }
  return FileSaveResult.saved;
}

@JS('voicechatFiles.beginSave')
external JSPromise<JSString?> _beginSave(JSString name);
@JS('voicechatFiles.write')
external JSPromise<JSAny?> _write(JSString id, JSUint8Array data);
@JS('voicechatFiles.finish')
external JSPromise<JSAny?> _finish(JSString id, JSBoolean success);
@JS('voicechatFiles.stream')
external JSPromise<JSString> _stream(
  JSString name,
  JSString mime,
  JSNumber size,
  JSFunction read,
);
@JS('voicechatFiles.download')
external JSPromise<JSAny?> _download(
  JSString name,
  JSString mime,
  JSNumber size,
  JSFunction read,
);
@JS('voicechatFiles.supportsSavePicker')
external JSBoolean _supportsSavePicker();
@JS('voicechatFiles.revoke')
external void _revoke(JSString url);
Future<void> cleanupRecordings() async {}
Future<void> deleteRecording(String path) async {
  if (path.startsWith('blob:')) _revoke(path.toJS);
}

Future<void> saveFile(
  ChunkedFile file,
  void Function(double) progress,
  bool Function() cancelled,
) async {
  if (!_supportsSavePicker().toDart) {
    try {
      await _download(
        file.name.toJS,
        file.mime.toJS,
        file.size.toJS,
        ((JSNumber from, JSNumber to) => (() async {
          if (cancelled()) throw StateError('Cancelled');
          final builder = BytesBuilder(copy: false);
          await for (final block in file.range(from.toDartInt, to.toDartInt)) {
            builder.add(block);
          }
          progress(to.toDartInt / file.size);
          return builder.takeBytes().toJS;
        })().toJS).toJS,
      ).toDart;
    } finally {
      file.clear();
    }
    return;
  }
  final id = (await _beginSave(file.name.toJS).toDart)?.toDart;
  if (id == null) return;
  var success = false;
  try {
    var written = 0;
    await for (final part in file.range(0, file.size)) {
      if (cancelled()) throw StateError('Cancelled');
      await _write(id.toJS, part.toJS).toDart;
      written += part.length;
      progress(written / file.size);
    }
    success = true;
  } finally {
    await _finish(id.toJS, success.toJS).toDart;
    file.clear();
  }
}

Future<({String url, Future<void> Function() close})> videoSource(
  ChunkedFile file,
) => _videoSource(file.name, file.mime, file.size, file.range);

Future<({String url, Future<void> Function() close})> draftVideoSource(
  PickedFile file,
) => _videoSource(file.name, file.mime, file.size, file.range);

Future<({String url, Future<void> Function() close})> _videoSource(
  String name,
  String mime,
  int size,
  Stream<Uint8List> Function(int, int) range,
) async {
  final url = (await _stream(
    name.toJS,
    mime.toJS,
    size.toJS,
    ((JSNumber from, JSNumber to) => (() async {
      final builder = BytesBuilder(copy: false);
      await for (final block in range(from.toDartInt, to.toDartInt)) {
        builder.add(block);
      }
      return builder.takeBytes().toJS;
    })().toJS).toJS,
  ).toDart).toDart;
  return (
    url: url,
    close: () async {
      _revoke(url.toJS);
    },
  );
}
