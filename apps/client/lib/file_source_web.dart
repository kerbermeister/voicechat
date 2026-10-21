import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'picked_file.dart';

Future<PickedFile?> chooseFile({bool video = false}) {
  final done = Completer<PickedFile?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = video ? 'video/*' : '*/*';
  input.style.display = 'none';
  input.addEventListener(
    'cancel',
    ((web.Event _) {
      input.remove();
      if (!done.isCompleted) done.complete(null);
    }).toJS,
  );
  input.addEventListener(
    'change',
    ((web.Event _) {
      final file = input.files?.item(0);
      input.remove();
      done.complete(
        file == null
            ? null
            : PickedFile(
                name: file.name,
                mime: file.type.isEmpty
                    ? 'application/octet-stream'
                    : file.type,
                size: file.size,
                read: (start, end) async =>
                    (await file.slice(start, end).arrayBuffer().toDart).toDart
                        .asUint8List(),
                release: () async {},
              ),
      );
    }).toJS,
  );
  web.document.body!.append(input);
  input.click();
  return done.future;
}
