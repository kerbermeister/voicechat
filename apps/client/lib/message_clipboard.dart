import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart' as mx;
import 'album_view.dart';
import 'chunked_file.dart';
import 'clipboard_file.dart';
import 'media_clipboard.dart';
import 'temporary_message.dart';
import 'user_action_error.dart';

Future<void> copyMessage(mx.Event event) async {
  if (event.redacted ||
      messageExpired(event) ||
      event.type == mx.EventTypes.Encrypted) {
    throw UserActionError('Содержимое сообщения недоступно.');
  }
  final cleanups = <void Function()>[];
  ClipboardFile attachment(mx.Event item) {
    if (item.messageType == 'dev.voicechat.file') {
      final file = ChunkedFile(item.room.client, item.content);
      cleanups.add(file.clear);
      return ClipboardFile(
        name: file.name,
        mime: file.mime,
        size: file.size,
        read: () async* {
          await for (final bytes in file.range(0, file.size)) {
            if (messageExpired(event)) throw StateError('Message expired');
            yield bytes;
          }
        },
      );
    }
    final size = item.infoMap['size'];
    if (!item.isAttachmentEncrypted ||
        size is! int ||
        size < 1 ||
        size > 10 * 1024 * 1024) {
      throw const FormatException('Invalid encrypted attachment');
    }
    return ClipboardFile(
      name: item.body,
      mime: item.infoMap['mimetype'] as String? ?? 'application/octet-stream',
      size: size,
      read: () async* {
        final file = await item.downloadAndDecryptAttachment();
        if (file.bytes.length != size || messageExpired(event)) {
          throw StateError('Attachment unavailable');
        }
        for (var offset = 0; offset < size; offset += 4 * 1024 * 1024) {
          yield Uint8List.sublistView(
            file.bytes,
            offset,
            (offset + 4 * 1024 * 1024).clamp(0, size),
          );
        }
      },
    );
  }

  try {
    final media = event.messageType == 'dev.voicechat.album'
        ? albumPhotos(event)
        : event.messageType == 'dev.voicechat.file' ||
              event.isAttachmentEncrypted
        ? [event]
        : <mx.Event>[];
    if (media.isEmpty) {
      await Clipboard.setData(
        ClipboardData(text: event.calcUnlocalizedBody(hideReply: true)),
      );
    } else {
      final files = <ClipboardFile>[];
      // Building descriptors does not download bytes before the browser's write gesture.
      for (final item in media) {
        files.add(attachment(item));
      }
      if (files.fold<int>(0, (sum, file) => sum + file.size) > 314572800) {
        throw UserActionError('Слишком большой объём для копирования.');
      }
      await copyMediaFiles(files);
    }
  } finally {
    for (final clear in cleanups) {
      clear();
    }
  }
}
