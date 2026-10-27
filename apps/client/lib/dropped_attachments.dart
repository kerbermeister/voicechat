import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'media_policy.dart';
import 'photo_processing.dart';
import 'picked_file.dart';
import 'user_action_error.dart';

/// Keep large files lazy; only supported static photos enter the photo pipeline.
Future<({List<MatrixImageFile> photos, List<PickedFile> files})>
prepareDroppedFiles(
  List<PickedFile> sources,
  MediaPolicy policy, {
  required int photoCount,
  required int fileCount,
}) async {
  bool photo(PickedFile file) => const [
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/bmp',
  ].contains(file.mime);
  final images = sources.where(photo).toList();
  final files = sources.where((file) => !photo(file)).toList();
  if (photoCount + images.length > policy.photoMaxCount ||
      fileCount + files.length > policy.fileMaxCount) {
    throw UserActionError(
      'Максимум ${policy.photoMaxCount} фото и ${policy.fileMaxCount} файлов.',
    );
  }
  for (final file in sources) {
    final limit = photo(file)
        ? policy.photoMaxBytes
        : file.mime.startsWith('video/')
        ? policy.videoMaxBytes
        : policy.fileMaxBytes;
    if (file.size <= 0 || file.size > limit) {
      throw UserActionError('Недопустимый размер файла «${file.name}».');
    }
  }
  final photos = <MatrixImageFile>[];
  for (final image in images) {
    final bytes = await image.read(0, image.size);
    if (bytes.length != image.size) {
      throw const FormatException('Incomplete image read');
    }
    photos.add(
      await compute((_) => compressPhoto(bytes, image.name, policy), null),
    );
  }
  return (photos: photos, files: files);
}
