import 'app_motion.dart';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart';
import 'image_source.dart';
import 'media_policy.dart';

Uint8List cropAvatar(Uint8List bytes, double zoom, double x, double y) {
  final source = img.decodeImage(bytes);
  if (source == null || zoom < 1 || zoom > 4 || x.abs() > 1 || y.abs() > 1) {
    throw const FormatException('Invalid avatar crop');
  }
  final side = (min(source.width, source.height) / zoom)
      .round()
      .clamp(1, min(source.width, source.height))
      .toInt();
  final left = ((source.width - side) * (x + 1) / 2).round();
  final top = ((source.height - side) * (y + 1) / 2).round();
  return Uint8List.fromList(
    img.encodeJpg(
      img.copyResize(
        img.copyCrop(source, x: left, y: top, width: side, height: side),
        width: 512,
        height: 512,
      ),
      quality: 85,
    ),
  );
}

Future<MatrixFile?> editAvatar(BuildContext context) async {
  final photos = await chooseImages(
    const MediaPolicy(photoMaxCount: 1, photoScale: 1),
    1,
  );
  if (photos.isEmpty || !context.mounted) return null;
  final bytes = await showDialog<Uint8List>(
    context: context,
    animationStyle: appAnimationStyle(context),
    builder: (_) => _AvatarEditor(bytes: photos.single.bytes),
  );
  return bytes == null
      ? null
      : MatrixFile(bytes: bytes, name: 'avatar.jpg', mimeType: 'image/jpeg');
}

class _AvatarEditor extends StatefulWidget {
  final Uint8List bytes;
  const _AvatarEditor({required this.bytes});
  @override
  State<_AvatarEditor> createState() => _AvatarEditorState();
}

class _AvatarEditorState extends State<_AvatarEditor> {
  double zoom = 1, x = 0, y = 0;
  late final dimensions = img.JpegDecoder().startDecode(widget.bytes)!;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Аватар'),
    content: SizedBox(
      width: 340,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onPanUpdate: (drag) => setState(() {
                x = (x - drag.delta.dx / 100).clamp(-1, 1);
                y = (y - drag.delta.dy / 100).clamp(-1, 1);
              }),
              child: ClipOval(
                child: SizedBox(
                  width: 220,
                  height: 220,
                  child: LayoutBuilder(
                    builder: (_, box) {
                      final side =
                          min(dimensions.width, dimensions.height) / zoom;
                      final scale = 220 / side;
                      return Stack(
                        children: [
                          Positioned(
                            left:
                                -(dimensions.width - side) *
                                (x + 1) /
                                2 *
                                scale,
                            top:
                                -(dimensions.height - side) *
                                (y + 1) /
                                2 *
                                scale,
                            width: dimensions.width * scale,
                            height: dimensions.height * scale,
                            child: Image.memory(
                              widget.bytes,
                              fit: BoxFit.fill,
                              cacheWidth: 1024,
                              gaplessPlayback: true,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Масштаб'),
            Slider(
              value: zoom,
              min: 1,
              max: 4,
              onChanged: (v) => setState(() => zoom = v),
            ),
            const Text('По горизонтали'),
            Slider(
              value: x,
              min: -1,
              max: 1,
              onChanged: (v) => setState(() => x = v),
            ),
            const Text('По вертикали'),
            Slider(
              value: y,
              min: -1,
              max: 1,
              onChanged: (v) => setState(() => y = v),
            ),
            const Text(
              'Аватар — метаданные профиля или группы. Он не защищён сквозным шифрованием переписки.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, cropAvatar(widget.bytes, zoom, x, y)),
        child: const Text('Сохранить'),
      ),
    ],
  );
}
