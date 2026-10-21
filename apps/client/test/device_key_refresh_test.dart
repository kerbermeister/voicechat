import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'chat_actions_test.dart' show OutboxDatabase;

class KeyDatabase extends OutboxDatabase {
  @override
  Future<void> transaction(Future<void> Function() action) => action();
  @override
  Future<void> storeDeviceKeysList(DeviceKeysList list) async {}
}

class KeyClient extends Client {
  final first = Completer<void>();
  int queries = 0, inFlight = 0, maximum = 0;
  KeyClient() : super('key-query-test', database: KeyDatabase());
  @override
  bool isLogged() => true;
  @override
  String get userID => '@self:local';
  @override
  Future<QueryKeysResponse> queryKeys(
    Map<String, List<String>> deviceKeys, {
    int? timeout,
  }) async {
    queries++;
    inFlight++;
    if (inFlight > maximum) maximum = inFlight;
    if (queries == 1) await first.future;
    inFlight--;
    return QueryKeysResponse.fromJson({
      'device_keys': {
        for (final user in deviceKeys.keys) user: <String, Object?>{},
      },
    });
  }
}

void main() {
  test(
    'Background sync and authorization cannot replace device lists concurrently',
    () async {
      final client = KeyClient();
      final first = client.updateUserDeviceKeys(additionalUsers: {'@a:local'});
      final second = client.updateUserDeviceKeys(additionalUsers: {'@b:local'});
      await Future<void>.delayed(Duration.zero);
      final maximum = client.maximum;
      client.first.complete();
      await Future.wait([first, second]);
      expect(maximum, 1);
      expect(client.queries, 2);
      expect(client.userDeviceKeys['@a:local']?.outdated, false);
      expect(client.userDeviceKeys['@b:local']?.outdated, false);
    },
  );
}
