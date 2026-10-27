import 'dart:typed_data';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;
import 'package:image/image.dart' as image;
import 'clipboard_file.dart';
import 'user_action_error.dart';

Future<void> copyMediaFiles(List<ClipboardFile> files) async {
  if (!web.window.isSecureContext ||
      !web.window.navigator.hasProperty('clipboard'.toJS).toDart) {
    throw UserActionError(
      'Этот браузер не предоставляет доступ к буферу обмена.',
    );
  }
  if (files.any((file) => !file.mime.startsWith('image/'))) {
    throw UserActionError(
      'Копирование настоящих файлов в буфер доступно в приложении Mac/Android. В этом браузере можно копировать текст и изображения.',
    );
  }
  final items = files.map((file) {
    final blob = (() async {
      if (file.size > 10 * 1024 * 1024) throw StateError('Image too large');
      final bytes = BytesBuilder(copy: false);
      await for (final part in file.read()) {
        bytes.add(part);
      }
      final data = bytes.takeBytes();
      if (data.length != file.size) throw StateError('Incomplete image');
      final header = image.findDecoderForData(data)?.startDecode(data);
      if (header == null ||
          header.width < 1 ||
          header.height < 1 ||
          header.width * header.height > 24000000) {
        throw StateError('Invalid image dimensions');
      }
      final decoded = image.decodeImage(data);
      if (decoded == null || decoded.width * decoded.height > 24000000) {
        throw StateError('Invalid image');
      }
      final png = Uint8List.fromList(image.encodePng(decoded));
      return web.Blob([png.toJS].toJS, web.BlobPropertyBag(type: 'image/png'));
    })().toJS;
    final formats = JSObject()..setProperty('image/png'.toJS, blob);
    return web.ClipboardItem(formats);
  }).toList();
  try {
    // Promise-backed items preserve Safari's user activation during decryption.
    await web.window.navigator.clipboard.write(items.toJS).toDart;
  } catch (_) {
    throw UserActionError(
      'Браузер не разрешил копирование. Попробуйте ещё раз; для альбома может понадобиться копировать фотографии по одной.',
    );
  }
}
