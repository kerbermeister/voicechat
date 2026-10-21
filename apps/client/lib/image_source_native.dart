import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

Future<MatrixFile?> chooseImage() async {
  final file = await const MethodChannel(
    'voicechat/images',
  ).invokeMapMethod<String, dynamic>('choose');
  if (file == null) return null;
  return MatrixFile.fromMimeType(
    bytes: file['bytes'] as Uint8List,
    name: file['name'] as String,
  );
}
