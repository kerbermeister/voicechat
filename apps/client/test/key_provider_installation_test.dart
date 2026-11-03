import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

class InstallingKeys implements rtc.KeyProvider {
  Future<bool> Function()? install;
  Future<void> Function()? installShared;
  Uint8List? received;
  String? participant;
  int? index;

  @override
  Future<bool> setKey({
    required String participantId,
    required int index,
    required Uint8List key,
  }) async {
    participant = participantId;
    this.index = index;
    received = key;
    return await install?.call() ?? true;
  }

  @override
  Future<void> setSharedKey({required Uint8List key, int index = 0}) async {
    received = key;
    this.index = index;
    await installShared?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'Sender index advances only after native key installation succeeds',
    () async {
      final native = InstallingKeys();
      final provider = lk.BaseKeyProvider(
        native,
        rtc.KeyProviderOptions(
          sharedKey: false,
          ratchetSalt: Uint8List(32),
          ratchetWindowSize: 16,
        ),
      );
      await provider.setRawKey(Uint8List(32), participantId: 'alice');
      final installed = Completer<bool>();
      native.install = () => installed.future;
      final pending = provider.setRawKey(
        Uint8List(32),
        participantId: 'alice',
        keyIndex: 1,
      );
      try {
        expect(provider.getLatestIndex('alice'), 0);
      } finally {
        installed.complete(true);
        await pending;
      }
      expect(provider.getLatestIndex('alice'), 1);
    },
  );

  for (final failure in ['false', 'exception']) {
    test(
      'Native key $failure preserves the last successful sender index',
      () async {
        final native = InstallingKeys();
        final provider = lk.BaseKeyProvider(
          native,
          rtc.KeyProviderOptions(
            sharedKey: false,
            ratchetSalt: Uint8List(32),
            ratchetWindowSize: 16,
          ),
        );
        await provider.setRawKey(Uint8List(32), participantId: 'alice');
        native.install = () async {
          if (failure == 'exception') throw StateError('Synthetic key failure');
          return false;
        };
        await expectLater(
          provider.setRawKey(
            Uint8List(32),
            participantId: 'alice',
            keyIndex: 1,
          ),
          throwsStateError,
        );
        expect(provider.getLatestIndex('alice'), 0);
      },
    );
  }

  test('Raw key installation preserves bytes, participant and slot', () async {
    final native = InstallingKeys();
    final provider = lk.BaseKeyProvider(
      native,
      rtc.KeyProviderOptions(
        sharedKey: false,
        ratchetSalt: Uint8List(32),
        ratchetWindowSize: 16,
      ),
    );
    final key = Uint8List.fromList(List.generate(32, (i) => 255 - i));
    await provider.setRawKey(key, participantId: 'alice', keyIndex: 3);
    expect(native.received, key);
    expect(native.participant, 'alice');
    expect(native.index, 3);
    expect(provider.getLatestIndex('alice'), 3);
    expect(provider.getLatestIndex('bob'), 0);
  });

  test('Pending shared key is not reported as installed', () async {
    final native = InstallingKeys();
    final provider = lk.BaseKeyProvider(
      native,
      rtc.KeyProviderOptions(
        sharedKey: true,
        ratchetSalt: Uint8List(32),
        ratchetWindowSize: 16,
      ),
    );
    final installed = Completer<void>();
    native.installShared = () => installed.future;
    final pending = provider.setSharedKey('new key');
    try {
      expect(provider.sharedKey, isNull);
    } finally {
      installed.complete();
      await pending;
    }
    expect(provider.sharedKey, 'new key'.codeUnits);
  });

  test(
    'Failed shared key preserves the last successfully installed key',
    () async {
      final native = InstallingKeys();
      final provider = lk.BaseKeyProvider(
        native,
        rtc.KeyProviderOptions(
          sharedKey: true,
          ratchetSalt: Uint8List(32),
          ratchetWindowSize: 16,
        ),
      );
      await provider.setSharedKey('previous key');
      native.installShared = () async =>
          throw StateError('Synthetic key failure');
      await expectLater(provider.setSharedKey('new key'), throwsStateError);
      expect(provider.sharedKey, 'previous key'.codeUnits);
    },
  );
}
