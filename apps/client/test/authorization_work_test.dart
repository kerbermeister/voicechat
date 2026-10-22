import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'chat_actions_test.dart' show OutboxDatabase;

class RecipientEncryption implements Encryption {
  int encryptions = 0;
  @override
  Future<Map<String, Map<String, Map<String, dynamic>>>> encryptToDeviceMessage(
    List<DeviceKeys> devices,
    String type,
    Map<String, dynamic> content,
  ) async {
    encryptions++;
    return {};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RecipientClient extends Client {
  RecipientClient() : super('empty-recipients', database: OutboxDatabase());
  @override
  final RecipientEncryption encryption = RecipientEncryption();
  @override
  bool get encryptionEnabled => true;
  int sends = 0;
  @override
  Future<void> sendToDevice(
    String type,
    String transaction,
    Map<String, Map<String, Map<String, Object?>>> messages,
  ) async {
    sends++;
  }
}

class MemberDatabase extends OutboxDatabase {
  int writes = 0;
  @override
  Future<List<User>> getUsers(Room room) async => [];
  @override
  Future<void> storeEventUpdate(
    String room,
    StrippedStateEvent event,
    EventUpdateType type,
    Client client,
  ) async {
    writes++;
  }
}

class MemberClient extends Client {
  final MemberDatabase store;
  MemberClient(this.store) : super('member-cache', database: store);
  List<MatrixEvent> members = [];
  int fetches = 0;
  @override
  Future<List<MatrixEvent>?> getMembersByRoom(
    String room, {
    String? at,
    Membership? membership,
    Membership? notMembership,
  }) async {
    fetches++;
    return members;
  }
}

void main() {
  test(
    'Empty encrypted recipient sets do no crypto, lock or network work',
    () async {
      final client = RecipientClient();
      await client.sendToDeviceEncrypted([], 'test.event', {});
      expect(client.encryption.encryptions, 0);
      expect(client.sends, 0);
    },
  );
  test(
    'Fresh member checks persist only changed events and still apply a real leave',
    () async {
      final database = MemberDatabase(), client = MemberClient(database);
      final room = Room(id: '!members:local', client: client);
      MatrixEvent member(String id, String membership) => MatrixEvent.fromJson({
        'event_id': id,
        'type': EventTypes.RoomMember,
        'state_key': '@peer:local',
        'sender': '@peer:local',
        'origin_server_ts': 1000,
        'content': {'membership': membership},
      });
      final filter = [Membership.join, Membership.leave];
      client.members = [member(r'$join', 'join')];
      await room.requestParticipants(filter, true, true, true);
      expect(database.writes, 1);
      expect(
        (room.getState(EventTypes.RoomMember, '@peer:local') as MatrixEvent)
            .eventId,
        r'$join',
      );
      await room.requestParticipants(filter, true, true, true);
      expect(database.writes, 1);
      expect(client.fetches, 2);
      client.members = [member(r'$leave', 'leave')];
      await room.requestParticipants(filter, true, true, true);
      expect(database.writes, 2);
      expect(room.getParticipants([Membership.join]), isEmpty);
      expect(room.getParticipants([Membership.leave]).single.id, '@peer:local');
    },
  );
}
