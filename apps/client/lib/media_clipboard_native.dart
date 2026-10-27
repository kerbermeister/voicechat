import 'package:flutter/services.dart';
import 'clipboard_file.dart';

const _clipboard = MethodChannel('voicechat/clipboard');
Future<void> copyMediaFiles(List<ClipboardFile> files) async {
  final ids = <String>[];
  try {
    for (final file in files) {
      final id = await _clipboard.invokeMethod<String>('begin', {
        'name': file.name,
        'mime': file.mime,
        'size': file.size,
      });
      if (id == null) throw StateError('Clipboard unavailable');
      ids.add(id);
      var written = 0;
      await for (final bytes in file.read()) {
        if (bytes.length > 4 * 1024 * 1024 ||
            written + bytes.length > file.size) {
          throw StateError('Invalid clipboard file range');
        }
        await _clipboard.invokeMethod<void>('write', {
          'id': id,
          'bytes': bytes,
        });
        written += bytes.length;
      }
      if (written != file.size) throw StateError('Incomplete clipboard file');
    }
    await _clipboard.invokeMethod<void>('commit', {'ids': ids});
  } catch (_) {
    if (ids.isNotEmpty) {
      await _clipboard.invokeMethod<void>('cancel', {'ids': ids});
    }
    rethrow;
  }
}
