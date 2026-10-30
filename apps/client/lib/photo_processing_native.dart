import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'media_policy.dart';
import 'photo_processing.dart';

Future<MatrixImageFile> processPhoto(
  Uint8List bytes,
  String name,
  MediaPolicy policy,
) => compute((_) => compressPhoto(bytes, name, policy), null);
