import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/utils/client_init_exception.dart';
import 'chat_actions_test.dart' show OutboxDatabase;

class InterruptedDatabase extends OutboxDatabase {
  int clears = 0, deletes = 0;
  @override
  Future<Map<String, dynamic>?> getClient(String name) async {
    throw TimeoutException('Temporary database failure');
  }

  @override
  Future<void> clear() async {
    clears++;
    values.clear();
  }

  @override
  Future<void> delete() async {
    deletes++;
    values.clear();
  }

  @override
  Future<void> close() async {}
}

void main() {
  test(
    'An interrupted session initialization never erases local keys or messages',
    () async {
      final database = InterruptedDatabase();
      database.values['retained'] = {'marker': 'encrypted keys and history'};
      final client = Client(
        'retained-session',
        database: database,
        logLevel: Level.error,
      );
      await expectLater(client.init(), throwsA(isA<ClientInitException>()));
      expect(database.clears, 0);
      expect(database.deletes, 0);
      expect(
        database.values['retained']?['marker'],
        'encrypted keys and history',
      );
      await client.dispose();
    },
  );
}
