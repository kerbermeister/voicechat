import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:image/image.dart' as img;
import 'media_policy.dart';
import 'photo_processing.dart';
import 'user_action_error.dart';

@JS('voicechatPhotos.normalize')
external JSPromise<_Photo> _normalize(
  JSUint8Array bytes,
  JSString mime,
  JSNumber maxPixels,
  JSNumber scale,
  JSNumber quality,
  JSNumber maxBytes,
);
extension type _Photo(JSObject _) implements JSObject {
  external JSUint8Array get bytes;
  external JSNumber get width;
  external JSNumber get height;
}

bool _nativePhoto(Uint8List bytes) =>
    (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) ||
    (bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp' &&
        [
          'heic',
          'heix',
          'hevc',
          'hevx',
          'mif1',
          'msf1',
        ].contains(String.fromCharCodes(bytes.sublist(8, 12))));

Future<MatrixImageFile> processPhoto(
  Uint8List bytes,
  String name,
  MediaPolicy policy,
) async {
  if (!_nativePhoto(bytes)) {
    return compute((_) => compressPhoto(bytes, name, policy), null);
  }
  if (bytes.isEmpty || bytes.length > 64 * 1024 * 1024) {
    throw UserActionError(
      'Исходная фотография превышает 64 МБ. Выберите меньший снимок.',
    );
  }
  // Inspect JPEG dimensions before asking the browser to allocate decoded pixels.
  if (bytes[0] == 0xff) {
    final info = img.JpegDecoder().startDecode(bytes);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width * info.height > 64000000) {
      throw UserActionError(
        'Исходная фотография превышает 64 Мп или повреждена.',
      );
    }
  }
  try {
    final result = await _normalize(
      bytes.toJS,
      (bytes[0] == 0xff ? 'image/jpeg' : 'image/heic').toJS,
      policy.photoMaxPixels.toJS,
      policy.photoScale.toJS,
      policy.photoJpegQuality.toJS,
      policy.photoMaxBytes.toJS,
    ).toDart;
    final output = result.bytes.toDart;
    final width = result.width.toDartInt, height = result.height.toDartInt;
    if (output.isEmpty ||
        output.length > policy.photoMaxBytes ||
        width <= 0 ||
        height <= 0 ||
        width * height > policy.photoMaxPixels) {
      throw const FormatException('Invalid normalized photo');
    }
    return MatrixImageFile(
      bytes: output,
      name: '${name.split('.').first}.jpg',
      mimeType: 'image/jpeg',
      width: width,
      height: height,
    );
  } catch (_) {
    throw UserActionError(
      'Не удалось обработать фотографию. Для HEIC нужен Safari 17 или новее. Выберите JPEG либо отправьте оригинал как файл. Максимум исходного снимка: 64 МБ и 64 Мп.',
    );
  }
}
