import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/matrix_probe.dart';

class RefreshClient implements Client {
  @override
  final userDeviceKeys = <String, DeviceKeysList>{};
  final firstStarted = Completer<void>(), secondStarted = Completer<void>();
  final firstSaved = Completer<void>(), secondResponse = Completer<void>();
  int calls = 0;
  bool failFirst = false;
  RefreshClient() {
    userDeviceKeys['@user:local'] = DeviceKeysList('@user:local', this);
  }

  @override
  Future<void> updateUserDeviceKeys({Set<String>? additionalUsers}) async {
    final list = userDeviceKeys['@user:local']!;
    if (++calls == 1) {
      // SDK applies the response before awaiting database persistence.
      list.outdated = failFirst;
      firstStarted.complete();
      await firstSaved.future;
    } else {
      secondStarted.complete();
      await secondResponse.future;
      list.outdated = false;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'Voice and screen refreshes cannot mark an unfinished refresh outdated',
    () async {
      final client = RefreshClient();
      final first = refreshDevices(client, {'@user:local'});
      await client.firstStarted.future;
      final second = refreshDevices(client, {'@user:local'});
      await Future<void>.delayed(Duration.zero);
      expect(client.calls, 1);
      expect(client.userDeviceKeys['@user:local']!.outdated, false);
      client.firstSaved.complete();
      await first;
      await client.secondStarted.future;
      client.secondResponse.complete();
      await second;
      expect(client.calls, 2);
    },
  );

  test(
    'A failed refresh denies access but does not poison the next refresh',
    () async {
      final client = RefreshClient()..failFirst = true;
      final first = refreshDevices(client, {'@user:local'});
      final denied = expectLater(first, throwsStateError);
      await client.firstStarted.future;
      final second = refreshDevices(client, {'@user:local'});
      client.firstSaved.complete();
      await denied;
      await client.secondStarted.future;
      client.secondResponse.complete();
      await second;
      expect(client.userDeviceKeys['@user:local']!.outdated, false);
    },
  );

  test('Different clients refresh independently', () async {
    final a = RefreshClient(), b = RefreshClient();
    final results = Future.wait([
      refreshDevices(a, {'@user:local'}),
      refreshDevices(b, {'@user:local'}),
    ]);
    await Future.wait([a.firstStarted.future, b.firstStarted.future]);
    a.firstSaved.complete();
    b.firstSaved.complete();
    await results;
  });
}
