import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/matrix_probe.dart';
import 'package:voicechat_probe/storage_policy.dart';
import 'package:voicechat_probe/picked_file.dart';
import 'package:voicechat_probe/local_store.dart';
import 'package:voicechat_probe/user_action_error.dart';
import 'dart:typed_data';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Trim encrypted local history and reload every message from the server',
    (tester) async {
      await tester.runAsync(() async {
        final probe = await MatrixProbe.open(
          'cache-${DateTime.now().millisecondsSinceEpoch}',
        );
        final policy = StoragePolicy(probe.client, () => null);
        final actions = ChatActions(probe.client);
        try {
          await probe.login(
            'http://localhost:8008',
            const String.fromEnvironment('UI_USERNAME'),
            const String.fromEnvironment('UI_PASSWORD'),
          );
          final room = await probe.room(
            await probe.createRoom([], name: 'Проверка локального кэша'),
          );
          await actions.open();
          for (var i = 0; i < 45; i++) {
            await actions.text(room, 'cache-message-$i');
          }
          final deadline = DateTime.now().add(const Duration(seconds: 90));
          while (actions.pending.isNotEmpty &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(actions.pending, isEmpty);
          var cancel = false;
          String? fileId;
          await expectLater(
            actions.file(
              room,
              PickedFile(
                name: 'cancel.bin',
                mime: 'application/octet-stream',
                size: 3 * fileChunkBytes,
                read: (from, to) async => Uint8List(to - from),
                release: () async {},
              ),
              '',
              cancelled: () => cancel,
              progress: (_) {
                fileId = actions.pending.last['id'] as String;
                cancel = true;
              },
            ),
            throwsA(isA<UserActionError>()),
          );
          expect(actions.pending, isEmpty);
          expect(fileId, isNotNull);
          expect(await readBlob(probe.client.clientName, '$fileId/0'), isNull);
          final fingerprint = probe.client.fingerprintKey;
          final oldIds = await probe.client.database.getEventIdList(room);
          expect(oldIds.length, greaterThan(30));
          expect(await policy.trimHistory(room), greaterThan(0));
          expect((await probe.client.database.getEventIdList(room)).length, 30);
          await policy.compact();
          expect(await policy.measure(), greaterThan(0));
          final timeline = await room.getTimeline(limit: 1000);
          try {
            for (
              var i = 0;
              i < 10 &&
                  !timeline.events.any((e) => e.body == 'cache-message-0');
              i++
            ) {
              await timeline.requestHistory(historyCount: 100);
            }
            expect(
              timeline.events
                  .where((e) => e.body.startsWith('cache-message-'))
                  .length,
              45,
            );
            expect(probe.client.fingerprintKey, fingerprint);
          } finally {
            timeline.cancelSubscriptions();
          }
        } finally {
          await actions.close();
          await policy.close();
          await probe.close();
        }
      });
    },
  );
}
