import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class CorruptDatabase implements MatrixSdkDatabase {
  bool cleared = false;
  @override
  Future<Map<String, dynamic>?> getClient(String name) async =>
      throw const DatabaseIntegrityException();
  @override
  Future<void> clear() async {
    cleared = true;
  }

  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test('Authenticated storage failure never clears local history', () async {
    final database = CorruptDatabase();
    final client = Client(
      'integrity-test',
      database: database,
      logLevel: Level.error,
    );
    final subscription = client.onLoginStateChanged.stream.listen(
      (_) {},
      onError: (Object _) {},
    );
    await expectLater(client.init(), throwsA(anything));
    expect(database.cleared, false);
    await subscription.cancel();
    await client.dispose();
  });
}
