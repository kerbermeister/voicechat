import 'package:flutter/services.dart';
import 'picked_file.dart';

const _channel = MethodChannel('voicechat/files');
Future<List<PickedFile>> chooseFiles({
  bool video = false,
  required int maxCount,
}) async {
  final files = await _channel.invokeListMethod<dynamic>('choose', {
    'video': video,
    'max_count': maxCount,
  });
  if (files == null) return [];
  return files
      .map((entry) => fileSource(Map<String, dynamic>.from(entry as Map)))
      .toList();
}

PickedFile fileSource(Map<String, dynamic> file) {
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
