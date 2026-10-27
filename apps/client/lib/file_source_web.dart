import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'picked_file.dart';
import 'user_action_error.dart';

Future<List<PickedFile>> chooseFiles({
  bool video = false,
  required int maxCount,
}) {
  final done = Completer<List<PickedFile>>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..multiple = true
    ..accept = video ? 'video/*' : '*/*';
  input.style.display = 'none';
  input.addEventListener(
    'cancel',
    ((web.Event _) {
      input.remove();
      if (!done.isCompleted) done.complete([]);
    }).toJS,
  );
  input.addEventListener(
    'change',
    ((web.Event _) {
      final files = input.files;
      input.remove();
      if (files == null) {
        done.complete([]);
        return;
      }
      if (files.length > maxCount) {
        done.completeError(
          UserActionError('Можно прикрепить ещё $maxCount файлов.'),
        );
        return;
      }
      done.complete([
        for (var i = 0; i < files.length; i++) fileSource(files.item(i)!),
      ]);
    }).toJS,
  );
  web.document.body!.append(input);
  input.click();
  return done.future;
}

PickedFile fileSource(web.File file) => PickedFile(
  name: file.name,
  mime: attachmentMime(file.name, file.type),
  size: file.size,
  read: (start, end) async =>
      (await file.slice(start, end).arrayBuffer().toDart).toDart.asUint8List(),
  release: () async {},
);
