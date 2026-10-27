import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voicechat_probe/dropped_attachments.dart';
import 'package:voicechat_probe/media_policy.dart';
import 'package:voicechat_probe/picked_file.dart';
import 'package:voicechat_probe/user_action_error.dart';

void main() {
  test(
    'Missing browser MIME uses known extensions but keeps explicit types',
    () {
      expect(attachmentMime('PHOTO.JPG', ''), 'image/jpeg');
      expect(
        attachmentMime('movie.mov', 'application/octet-stream'),
        'video/quicktime',
      );
      expect(attachmentMime('unknown.bin', ''), 'application/octet-stream');
      expect(attachmentMime('png', ''), 'application/octet-stream');
      expect(attachmentMime('fake.jpg', 'text/plain'), 'text/plain');
    },
  );
  PickedFile source(
    String mime,
    Uint8List bytes, {
    int? size,
    void Function()? read,
  }) => PickedFile(
    name: 'example',
    mime: mime,
    size: size ?? bytes.length,
    read: (start, end) async {
      read?.call();
      return bytes;
    },
    release: () async {},
  );
  test(
    'Mixed drop processes photos and keeps video and documents lazy',
    () async {
      final png = Uint8List.fromList(
        img.encodePng(img.Image(width: 20, height: 12)),
      );
      var reads = 0;
      final photo = source('image/png', png);
      final video = source('video/mp4', Uint8List(4), read: () => reads++);
      final pdf = source('application/pdf', Uint8List(4), read: () => reads++);
      final result = await prepareDroppedFiles(
        [photo, video, pdf],
        const MediaPolicy(),
        photoCount: 0,
        fileCount: 0,
      );
      expect(result.photos.single.width, 10);
      expect(result.photos.single.height, 6);
      expect(result.files, [video, pdf]);
      expect(reads, 0);
    },
  );
  test(
    'Count and size limits reject before reading, corrupt photos fail',
    () async {
      var reads = 0;
      final large = source(
        'image/png',
        Uint8List(1),
        size: 10485761,
        read: () => reads++,
      );
      final file = source('video/mp4', Uint8List(1), read: () => reads++);
      for (final sources in [
        [large],
        [file],
      ]) {
        await expectLater(
          prepareDroppedFiles(
            sources,
            const MediaPolicy(),
            photoCount: 0,
            fileCount: 5,
          ),
          throwsA(isA<UserActionError>()),
        );
      }
      expect(reads, 0);
      await expectLater(
        prepareDroppedFiles(
          [source('image/png', Uint8List(5))],
          const MediaPolicy(),
          photoCount: 0,
          fileCount: 0,
        ),
        throwsA(isA<UserActionError>()),
      );
    },
  );
}
