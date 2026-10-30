import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'chat_actions_test.dart' show OutboxDatabase;
import 'message_test.dart' show TestClient;

class MediaDatabase extends OutboxDatabase {
  @override
  Future<void> transaction(Future<void> Function() action) => action();
  @override
  Future<void> storeFile(Uri uri, Uint8List bytes, int time) async {}
  @override
  Future<bool> deleteFile(Uri uri) async => true;
}

class MediaClient extends TestClient {
  @override
  final database = MediaDatabase();
  final upload = Completer<Uri>();
  final started = Completer<void>();
  @override
  Duration get sendTimelineEventTimeout => const Duration(minutes: 1);
  @override
  Future<MediaConfig> getConfig({
    Duration cacheLifetime = const Duration(days: 3),
    bool throwOnUpdateFailure = false,
  }) async => MediaConfig(mUploadSize: 10000);
  @override
  Future<Uri> uploadContent(
    Uint8List file, {
    String? filename,
    String? contentType,
  }) {
    started.complete();
    return upload.future;
  }

  @override
  Future<void> handleSync(SyncUpdate sync, {Direction? direction}) async {}
  @override
  dynamic noSuchMethod(Invocation i) =>
      i.memberName == #customVideoThumbnailGenerator
      ? null
      : super.noSuchMethod(i);
}

class MediaRoom extends Room {
  MediaRoom(Client client) : super(client: client, id: '!fixture:local');
  // Synthetic unencrypted bytes isolate the SDK upload/publication ordering.
  @override
  bool get encrypted => false;
  final published = <String?>[];
  @override
  Future<String?> sendEvent(
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
  }) async {
    published.add(txid);
    return r'$confirmed';
  }
}

void main() {
  for (final allowed in [false, true]) {
    test(
      'Actual SDK checks publication guard after upload (allowed=$allowed)',
      () async {
        final client = MediaClient();
        final room = MediaRoom(client);
        var paused = false, checked = false;
        final result = room.sendFileEvent(
          MatrixFile(bytes: Uint8List.fromList([1, 2, 3]), name: 'fixture.bin'),
          txid: 'same-id',
          beforeSend: () async {
            checked = true;
            if (paused) throw StateError('Deadline expired');
          },
        );
        final expectation = allowed
            ? expectLater(result, completion(r'$confirmed'))
            : expectLater(result, throwsStateError);
        await client.started.future;
        expect(checked, false);
        expect(room.published, isEmpty);
        paused = !allowed;
        client.upload.complete(Uri.parse('mxc://fixture.local/test'));
        await expectation;
        expect(checked, true);
        expect(room.published, allowed ? ['same-id'] : isEmpty);
      },
    );
  }
}
