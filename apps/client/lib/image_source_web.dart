import 'dart:async';
import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:web/web.dart' as web;
import 'media_policy.dart';
import 'photo_processing.dart';
import 'user_action_error.dart';

Future<List<MatrixImageFile>> chooseImages(
  MediaPolicy policy,
  int remaining, {
  bool camera = false,
}) {
  final done = Completer<List<MatrixImageFile>>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = 'image/*'
    ..multiple = !camera;
  if (camera) input.setAttribute('capture', 'environment');
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
      unawaited(() async {
        try {
          final files = input.files;
          if (files == null) {
            done.complete([]);
            return;
          }
          if (files.length > remaining) {
            throw UserActionError(
              'Можно прикрепить ещё $remaining фото; максимум ${policy.photoMaxCount}.',
            );
          }
          final photos = <MatrixImageFile>[];
          for (var i = 0; i < files.length; i++) {
            final file = files.item(i)!;
            if (file.size <= 0 || file.size > policy.photoMaxBytes) {
              throw UserActionError('Фотография превышает допустимый размер.');
            }
            final bytes = (await file.arrayBuffer().toDart).toDart
                .asUint8List();
            await Future<void>.delayed(const Duration(milliseconds: 16));
            photos.add(
              await compute(
                (_) => compressPhoto(bytes, file.name, policy),
                null,
              ),
            );
          }
          done.complete(photos);
        } catch (error, stack) {
          done.completeError(error, stack);
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
