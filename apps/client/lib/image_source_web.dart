import 'dart:async';
import 'dart:js_interop';
import 'package:matrix/matrix.dart';
import 'package:web/web.dart' as web;
import 'chat_actions.dart';

Future<MatrixFile?> chooseImage() {
  final done = Completer<MatrixFile?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = 'image/*';
  input.style.display = 'none';
  void cancel(web.Event _) {
    input.remove();
    if (!done.isCompleted) done.complete();
  }

  input.addEventListener('cancel', cancel.toJS);
  input.addEventListener(
    'change',
    ((web.Event _) {
      unawaited(() async {
        try {
          final file = input.files?.item(0);
          if (file == null) {
            if (!done.isCompleted) done.complete();
            return;
          }
          if (file.size <= 0 || file.size > maxAttachmentBytes) {
            throw StateError('Image exceeds 10 MB');
          }
          final bytes = (await file.arrayBuffer().toDart).toDart.asUint8List();
          if (!done.isCompleted) {
            done.complete(
              MatrixFile.fromMimeType(bytes: bytes, name: file.name),
            );
          }
        } catch (error, stack) {
          if (!done.isCompleted) done.completeError(error, stack);
        } finally {
          input.remove();
        }
      }());
    }).toJS,
  );
  web.document.body!.append(input);
  input.click();
  return done.future;
}
