import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'chat_actions_test.dart' show OutboxDatabase;

class LocalDataDatabase extends OutboxDatabase {
  @override
  Future<void> close() async {}
}

void main() {
  test(
    'remote account data cannot replace local trust pins, consent or the outbox',
    () async {
      final database = LocalDataDatabase();
      final client = Client('local-data-test', database: database);
      addTearDown(client.dispose);
      final local = [
        'dev.voicechat.local.first_keys',
        'dev.voicechat.local.contacts',
        'dev.voicechat.local.outbox',
        'dev.voicechat.local.drafts',
        'dev.voicechat.local.history:!room:local',
      ];
      for (final type in local) {
        await database.storeAccountData(type, {'protected': true});
      }
      await client.handleSync(
        SyncUpdate(
          nextBatch: 'test',
          accountData: [
            for (final type in local)
              BasicEvent(type: type, content: {'protected': false}),
            BasicEvent(type: 'm.example', content: {'normal': true}),
          ],
        ),
      );
      for (final type in local) {
        expect(database.values[type], {'protected': true});
      }
      expect(database.values['m.example'], {'normal': true});
      expect(client.accountData['m.example']?.content, {'normal': true});
    },
  );
}
