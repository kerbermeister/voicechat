import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart';
import 'media_policy.dart';
import 'user_action_error.dart';

MatrixImageFile compressPhoto(
  Uint8List bytes,
  String name,
  MediaPolicy policy,
) {
  if (bytes.isEmpty || bytes.length > policy.photoMaxBytes) {
    throw UserActionError('Фотография превышает допустимый размер.');
  }
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > policy.photoMaxPixels) {
    throw UserActionError(
      'Изображение повреждено, слишком большое или формат не поддерживается.',
    );
  }
  if (decoder!.numFrames() > 1) {
    throw UserActionError(
      'Выберите статичную фотографию. Анимацию можно будет отправить как файл.',
    );
  }
  final decoded = decoder.decodeFrame(0);
  if (decoded == null) {
    throw UserActionError('Не удалось прочитать фотографию.');
  }
  final oriented = img.bakeOrientation(decoded);
  final resized = img.copyResize(
    oriented,
    width: (oriented.width * policy.photoScale).round().clamp(
      1,
      oriented.width,
    ),
    height: (oriented.height * policy.photoScale).round().clamp(
      1,
      oriented.height,
    ),
    interpolation: img.Interpolation.average,
  );
  final canvas = img.Image(
    width: resized.width,
    height: resized.height,
    numChannels: 3,
  );
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(canvas, resized);
  // JPEG output intentionally carries no source EXIF or location metadata.
  final output = img.encodeJpg(canvas, quality: policy.photoJpegQuality);
  if (output.length > policy.photoMaxBytes) {
    throw UserActionError(
      'После обработки фотография всё ещё слишком большая.',
    );
  }
  return MatrixImageFile(
    bytes: output,
    name: '${name.split('.').first}.jpg',
    mimeType: 'image/jpeg',
    width: canvas.width,
    height: canvas.height,
  );
}
