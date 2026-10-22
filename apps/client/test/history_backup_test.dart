import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
// ignore: implementation_imports
import 'package:matrix/encryption/utils/stored_inbound_group_session.dart';
import 'package:voicechat_probe/matrix_probe.dart';
import 'package:voicechat_probe/user_action_error.dart';

class BackupManager implements KeyManager {
  bool cached = false, uploadSucceeds = false;
  int uploads = 0;
  final pending = [
    StoredInboundGroupSession(
      roomId: '!room:local',
      sessionId: 'session',
      pickle: 'encrypted',
      content: '{}',
      indexes: '{}',
      allowedAtIndex: '{}',
      senderKey: 'sender',
      senderClaimedKeys: '{}',
    ),
  ];
  @override
  Future<bool> isCached() async => cached;
  @override
  Future<void> uploadInboundGroupSessions({
    bool skipIfInProgress = false,
  }) async {
    uploads++;
    if (uploadSucceeds) pending.clear();
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class BackupDatabase implements MatrixSdkDatabase {
  final BackupManager manager;
  BackupDatabase(this.manager);
  @override
  Future<List<StoredInboundGroupSession>>
  getInboundGroupSessionsToUpload() async => manager.pending;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class BackupEncryption implements Encryption {
  @override
  final KeyManager keyManager;
  BackupEncryption(this.keyManager);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class BackupClient implements Client {
  final manager = BackupManager();
  Object? failure;
  int checks = 0;
  @override
  late final database = BackupDatabase(manager);
  @override
  late final encryption = BackupEncryption(manager);
  @override
  Future<GetRoomKeysVersionCurrentResponse> getRoomKeysVersionCurrent() async {
    checks++;
    if (failure != null) throw failure!;
    return GetRoomKeysVersionCurrentResponse(
      algorithm: BackupAlgorithm.mMegolmBackupV1Curve25519AesSha2,
      authData: {},
      count: 0,
      etag: '0',
      version: '1',
    );
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test('Unconfigured backup never reports success', () async {
    final client = BackupClient();
    expect(await MatrixProbe(client).backup(), false);
    expect(client.manager.uploads, 0);
  });
  test(
    'Silent SDK upload failure prevents success and destructive logout',
    () async {
      final client = BackupClient()..manager.cached = true;
      final probe = MatrixProbe(client);
      await expectLater(probe.backup(), throwsA(isA<UserActionError>()));
      await expectLater(probe.logout(), throwsA(isA<UserActionError>()));
      expect(client.manager.pending, hasLength(1));
      client.manager.uploadSucceeds = true;
      expect(await probe.backup(), true);
      expect(client.manager.pending, isEmpty);
    },
  );
  test(
    'Missing backup is explained without masking network failures',
    () async {
      final client = BackupClient()
        ..failure = MatrixException.fromJson({'errcode': 'M_NOT_FOUND'});
      final probe = MatrixProbe(client);
      await expectLater(
        probe.restore('not-a-secret'),
        throwsA(isA<UserActionError>()),
      );
      final network = TimeoutException('offline');
      client.failure = network;
      await expectLater(probe.requireHistoryBackup(), throwsA(same(network)));
    },
  );
}
