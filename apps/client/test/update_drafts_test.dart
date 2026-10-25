import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/chat_actions.dart';
import 'chat_actions_test.dart' show OutboxDatabase;

void main() {
  test(
    'drafts survive reopening, latest snapshot wins, write failure blocks update',
    () async {
      final database = OutboxDatabase();
      final client = Client('draft-test', database: database);
      final actions = ChatActions(client);
      await actions.open();
      await actions.saveDraft('!room:test', 'Сохранённый черновик');
      await actions.prepareUpdate();
      await actions.close();
      final reopened = ChatActions(client);
      await reopened.open();
      expect(reopened.drafts['!room:test'], 'Сохранённый черновик');
      final first = reopened.saveDraft('!room:test', 'first');
      final second = reopened.saveDraft('!room:test', 'second');
      await Future.wait([first, second]);
      expect(
        database.values['dev.voicechat.local.drafts']!['!room:test'],
        'second',
      );
      database.failWrite = true;
      await expectLater(
        reopened.saveDraft('!room:test', 'third'),
        throwsStateError,
      );
      await expectLater(reopened.prepareUpdate(), throwsStateError);
      expect(
        database.values['dev.voicechat.local.drafts']!['!room:test'],
        'second',
      );
      database.failWrite = false;
      await reopened.saveDraft('!room:test', '');
      await reopened.prepareUpdate();
      expect(database.values['dev.voicechat.local.drafts'], isEmpty);
      await reopened.close();
    },
  );
}
