// UA-32.C05: production message and gallery widgets, synthetic photo bytes only.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/chat_pane.dart';
import 'package:voicechat_probe/temporary_message.dart';

import '../../../apps/client/test/conversation_list_test.dart' show ListClient;

class Photo extends mx.Event {
  final Uint8List bytes;
  Photo(mx.Room room, Uint8List data)
    : bytes = data,
      super(
        room: room,
        eventId: r'$ephemeral-photo',
        type: mx.EventTypes.Message,
        senderId: '@qa:local',
        originServerTs: DateTime.now(),
        content: {
          'msgtype': mx.MessageTypes.Image,
          'body': 'qa.png',
          'info': {'size': data.length, 'mimetype': 'image/png'},
          'dev.voicechat.ttl_seconds': 10,
        },
      );
  @override
  bool get isAttachmentEncrypted => true;
  @override
  Future<mx.MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    bool skipScanner = false,
    void Function(int)? onDownloadProgress,
  }) async =>
      mx.MatrixFile(bytes: bytes, name: 'qa.png', mimeType: 'image/png');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'UA-32.C05 photo opened before TTL must disappear from the gallery at expiry',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final name in [
        'xyz.luan/audioplayers.global',
        'xyz.luan/audioplayers.global/events',
        'xyz.luan/audioplayers',
      ]) {
        messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
          if (call.method == 'create') {
            final id = (call.arguments as Map)['playerId'];
            messenger.setMockMethodCallHandler(
              MethodChannel('xyz.luan/audioplayers/events/$id'),
              (_) async => null,
            );
          }
          return null;
        });
      }
      final room = mx.Room(id: '!qa:local', client: ListClient());
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 10, height: 10)),
      );
      final event = Photo(room, bytes);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TemporaryMessage(
              event: event,
              child: AttachmentView(event: event),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(Image), findsOneWidget);
      await tester.tap(find.byType(Image));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byTooltip('Закрыть просмотр'), findsOneWidget);
      await tester.pump(const Duration(seconds: 12));
      final stillVisible = find.byType(Image).evaluate().length;
      final galleryStillOpen = find
          .byTooltip('Закрыть просмотр')
          .evaluate()
          .isNotEmpty;
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(
        stillVisible,
        0,
        reason: 'The parent TTL elapsed, but its modal gallery still holds decrypted bytes',
      );
      expect(galleryStillOpen, false);
    },
  );
}
