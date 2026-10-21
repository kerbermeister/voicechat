import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';
import 'media_policy.dart';
import 'photo_processing.dart';
import 'user_action_error.dart';

Future<List<MatrixImageFile>> chooseImages(
  MediaPolicy policy,
  int remaining,
) async {
  const channel = MethodChannel('voicechat/images');
  final uris = await channel.invokeListMethod<String>('choose', {
    'max_count': remaining,
  });
  if (uris == null) return [];
  if (uris.length > remaining) {
    throw UserActionError(
      'Слишком много фотографий. Максимум ${policy.photoMaxCount}.',
    );
  }
  final photos = <MatrixImageFile>[];
  // Read/decode one original at a time rather than retaining 24 full-sized source images.
  for (final uri in uris) {
    final file = await channel.invokeMapMethod<String, dynamic>('read', {
      'uri': uri,
      'max_bytes': policy.photoMaxBytes,
    });
    if (file == null) {
      throw UserActionError('Фотография больше недоступна. Выберите её снова.');
    }
    photos.add(
      await compute(
        (_) => compressPhoto(
          file['bytes'] as Uint8List,
          file['name'] as String,
          policy,
        ),
        null,
      ),
    );
  }
  return photos;
}
