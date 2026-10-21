import 'package:flutter/services.dart';
import 'picked_file.dart';

const _channel = MethodChannel('voicechat/files');
Future<PickedFile?> chooseFile({bool video = false}) async {
  final file = await _channel.invokeMapMethod<String, dynamic>('choose', {
    'video': video,
  });
  if (file == null) return null;
  final uri = file['uri'] as String;
  return PickedFile(
    name: file['name'] as String,
    mime: file['mime'] as String,
    size: file['size'] as int,
    read: (start, end) async => (await _channel.invokeMethod<Uint8List>(
      'read',
      {'uri': uri, 'start': start, 'end': end},
    ))!,
    release: () async {
      await _channel.invokeMethod<void>('release', {'uri': uri});
    },
  );
}
