// Disposable integration fixtures, used only by lab_main.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as mx;
import 'chat_actions.dart';
import 'matrix_probe.dart';
import 'voice_recording.dart';

Uint8List get testImage => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aNioAAAAASUVORK5CYII=',
);
Uint8List get testVoice => voiceWav(Uint8List(3200));
void check(bool condition, String failure) {
  if (!condition) throw StateError(failure);
}

Future<void> waitCheck(
  Future<bool> Function() condition,
  String failure,
) async {
  final end = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(end)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw StateError(failure);
}

Future<void> exerciseMessages(
  MatrixProbe probe,
  mx.Room room,
  String run,
) async {
  var queue = ChatActions(probe.client);
  await queue.open();
  final originalHttp = probe.client.httpClient;
  try {
    // Simulate real transport failure, persist, close and reload the encrypted outbox.
    probe.client.httpClient = MockClient((_) async => http.Response('{}', 503));
    await queue.text(room, 'offline-$run');
    final transaction = queue.pending.single['id'];
    await queue.close();
    queue = ChatActions(probe.client);
    await queue.open();
    check(
      queue.pending.single['id'] == transaction,
      'Outbox lost its transaction ID',
    );
  } finally {
    probe.client.httpClient = originalHttp;
  }
  try {
    await queue.flush();
    await waitCheck(() async => queue.pending.isEmpty, 'Outbox did not drain');
    final timeline = await room.getTimeline();
    try {
      await waitCheck(
        () async => visibleMessages(timeline, 'offline-$run').length == 1,
        'Offline send missing or duplicated',
      );
      final original = visibleMessages(timeline, 'offline-$run').single;
      await queue.text(room, 'reply-$run', reply: original);
      await waitCheck(() async => queue.pending.isEmpty, 'Reply did not send');
      await queue.text(room, 'edited-$run', edit: original.eventId);
      await waitCheck(() async => queue.pending.isEmpty, 'Edit did not send');
      await waitCheck(
        () async => original.getDisplayEvent(timeline).body == 'edited-$run',
        'Edit not applied',
      );
      check(
        visibleMessages(
          timeline,
          'offline-$run',
        ).every((e) => e.eventId != original.eventId),
        'Search indexed old edit',
      );
      await queue.enqueue(room, {
        'm.relates_to': {
          'rel_type': mx.RelationshipTypes.reaction,
          'event_id': original.eventId,
          'key': '👍',
        },
      }, type: mx.EventTypes.Reaction);
      await waitCheck(
        () async => queue.pending.isEmpty,
        'Reaction did not send',
      );
      await waitCheck(
        () async => original
            .aggregatedEvents(timeline, mx.RelationshipTypes.reaction)
            .isNotEmpty,
        'Reaction not aggregated',
      );
      final reply = timeline.events.firstWhere(
        (e) => e.inReplyToEventId() == original.eventId,
      );
      check(
        (await reply.getReplyEvent(timeline))?.eventId == original.eventId,
        'Reply relation lost',
      );
      final wire = await probe.client.getOneRoomEvent(
        room.id,
        original.eventId,
      );
      check(
        wire.type == mx.EventTypes.Encrypted &&
            !jsonEncode(wire.content).contains('offline-$run'),
        'Plaintext content on server',
      );
      await queue.text(room, 'delete-$run');
      await waitCheck(
        () async => queue.pending.isEmpty,
        'Delete fixture did not send',
      );
      await waitCheck(
        () async => visibleMessages(timeline, 'delete-$run').isNotEmpty,
        'Delete fixture missing',
      );
      final removable = visibleMessages(timeline, 'delete-$run').single;
      await removable.redactEvent();
      await waitCheck(
        () async => timeline.events.any(
          (e) => e.eventId == removable.eventId && e.redacted,
        ),
        'Redaction did not apply',
      );
      await queue.attachment(
        room,
        mx.MatrixImageFile(
          bytes: testImage,
          name: 'test-image.png',
          mimeType: 'image/png',
        ),
      );
      await queue.attachment(
        room,
        mx.MatrixAudioFile(
          bytes: testVoice,
          name: 'test-voice.wav',
          mimeType: 'audio/wav',
          duration: 100,
        ),
      );
      await waitCheck(
        () async => queue.pending.isEmpty,
        'Attachments did not send',
      );
      await checkAttachments(room, serverCiphertext: true);
    } finally {
      timeline.cancelSubscriptions();
    }
  } finally {
    await queue.close();
  }
}

Future<void> checkAttachments(
  mx.Room room, {
  bool serverCiphertext = false,
}) async {
  final timeline = await room.getTimeline();
  try {
    for (final fixture in {
      'test-image.png': testImage,
      'test-voice.wav': testVoice,
    }.entries) {
      await waitCheck(
        () async => timeline.events.any(
          (e) => e.body == fixture.key && e.status.isSent,
        ),
        'Attachment event missing',
      );
      final event = timeline.events.firstWhere(
        (e) => e.body == fixture.key && e.status.isSent,
      );
      check(event.isAttachmentEncrypted, 'Plaintext attachment descriptor');
      final file = await event.downloadAndDecryptAttachment();
      check(
        base64Encode(file.bytes) == base64Encode(fixture.value),
        'Attachment decrypt mismatch',
      );
      if (serverCiphertext) {
        final mxc = event.attachmentMxcUrl!;
        final url = room.client.homeserver!.resolve(
          '_matrix/client/v1/media/download/${mxc.host}${mxc.path}',
        );
        final response = await room.client.httpClient.get(
          url,
          headers: {'Authorization': 'Bearer ${room.client.accessToken}'},
        );
        check(
          response.statusCode == 200 &&
              base64Encode(response.bodyBytes) != base64Encode(fixture.value),
          'Server stored plaintext media',
        );
      }
    }
  } finally {
    timeline.cancelSubscriptions();
  }
}
