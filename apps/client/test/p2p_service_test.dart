import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/utils/cached_stream_controller.dart';
import 'package:voicechat_probe/contact_service.dart';
import 'package:voicechat_probe/p2p/service.dart';
import 'package:voicechat_probe/p2p/protocol.dart';
import 'package:voicechat_probe/picked_file.dart';
import 'message_test.dart' show OfflineClient, OfflinePeer, TestRoom;
import 'chat_actions_test.dart' show OutboxDatabase;

class P2pClient extends OfflineClient {
  @override
  final database = OutboxDatabase();
  @override
  String get clientName => 'p2p-test';
  final _events = CachedStreamController<ToDeviceEvent>();
  @override
  CachedStreamController<ToDeviceEvent> get onToDeviceEvent => _events;
  @override
  http.Client get httpClient => _http;
  final _http = MockClient(
    (_) async => http.Response(
      jsonEncode({
        'p2p_file_max_bytes': 5000000000,
        'p2p_file_max_count': 10,
        'p2p_max_recipients': 4,
      }),
      200,
    ),
  );
  @override
  List<Room> get rooms => [];
  late final room = PeerRoom(this);
  final sent = <Map<String, dynamic>>[];
  @override
  Room? getRoomById(String id) => id == room.id ? room : null;
  @override
  DeviceKeys? getUserDeviceKeysByCurve25519Key(String key) => key == 'known'
      ? userDeviceKeys['@peer:local']!.deviceKeys['DEVICE']
      : null;
  @override
  Future<Map<String, RoomMember>?> getJoinedMembersByRoom(String id) async => {
    userID: RoomMember(),
    '@peer:local': RoomMember(),
  };
  @override
  Future<void> sendToDeviceEncrypted(
    List<DeviceKeys> devices,
    String type,
    Map<String, dynamic> content, {
    String? messageId,
    bool onlyVerified = false,
  }) async {
    expect(onlyVerified, true);
    expect(
      devices.every((d) => d.directVerified && d.userId == '@peer:local'),
      true,
    );
    sent.add(Map.of(content));
  }
}

class PeerRoom extends TestRoom {
  final P2pClient _client;
  @override
  P2pClient get client => _client;
  PeerRoom(this._client) : super(true, null);
}

class Friends extends ContactService {
  Friends(Client client) : super(client, 'https://local.invalid') {
    available = true;
    requests = [
      ContactRequest.fromJson({
        'id': 'a' * 32,
        'sender': client.userID,
        'recipient': '@peer:local',
        'room_id': '!room:local',
        'state': 'accepted',
      }),
    ];
  }
  @override
  Future<void> refresh() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late P2pClient client;
  late Friends friends;
  late P2pService service;
  setUp(() async {
    client = P2pClient();
    friends = Friends(client);
    service = P2pService(client, friends, 'https://local.invalid');
    await service.open();
  });
  tearDown(() async {
    await service.close();
    await client.onToDeviceEvent.close();
    await friends.close();
  });
  Future<void> emit(
    Map<String, dynamic> data, {
    String? key = 'known',
    String sender = '@peer:local',
  }) async {
    client.onToDeviceEvent.add(
      ToDeviceEvent(
        sender: sender,
        type: P2pService.eventType,
        content: data,
        encryptedContent: key == null ? null : {'sender_key': key},
      ),
    );
    // Drain the serial event queue and HTTP/database microtasks without wall-clock sleeps.
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Map<String, dynamic> offer(String id) => {
    'v': 1,
    'id': id,
    'room': '!room:local',
    'to': client.userID,
    'op': 'offer',
    'expires': DateTime.now().millisecondsSinceEpoch + 60000,
    'files': [
      P2pFile('empty.txt', 'text/plain', 0, P2pHash().finish()).toJson(),
    ],
  };
  test(
    'Only encrypted trusted accepted contact can offer; duplicate and late events are ignored',
    () async {
      final data = offer('b' * 32);
      await emit(data, key: null);
      await emit(data, key: 'unknown');
      await emit(data, sender: '@stranger:local');
      expect(service.transfers, isEmpty);
      final device =
          client.userDeviceKeys['@peer:local']!.deviceKeys['DEVICE']!
              as OfflinePeer;
      device.directVerified = false;
      await emit(data);
      expect(service.transfers, isEmpty);
      device.directVerified = true;
      friends.requests = [];
      await emit(data);
      expect(service.transfers, isEmpty);
      friends = Friends(client);
      service.contacts.requests = friends.requests;
      await emit({...data, 'expires': 1});
      expect(service.transfers, isEmpty);
      await emit(data);
      await emit(data);
      expect(service.transfers, hasLength(1));
      expect(service.transfers.single.state, P2pState.offered);
      expect(service.transfers.single.wire, isNull);
      await service.remove(service.transfers.single);
      await emit(data);
      expect(service.transfers, isEmpty);
    },
  );
  test(
    'Offer sends no bytes; cancel releases a shared source only after last recipient session',
    () async {
      var reads = 0, releases = 0;
      final sources = [
        PickedFile(
          name: 'empty',
          mime: 'text/plain',
          size: 0,
          read: (_, __) async {
            reads++;
            return Uint8List(0);
          },
          release: () async {
            releases++;
          },
        ),
      ];
      await service.send(['@peer:local'], sources);
      expect(client.sent.single['op'], 'offer');
      expect(reads, 0);
      expect(releases, 0);
      final first = service.transfers.single;
      service.transfers.add(
        P2pTransfer(
          id: 'c' * 32,
          roomId: first.roomId,
          peer: first.peer,
          outgoing: true,
          files: first.files,
          expires: first.expires,
          sources: sources,
        ),
      );
      await service.cancel(first);
      expect(releases, 0);
      await service.cancel(service.transfers.last);
      expect(releases, 1);
      await service.cancel(first);
      expect(releases, 1);
    },
  );
  test(
    'Server recipient bound applies across packages before reading or inviting',
    () async {
      final files = [P2pFile('empty', 'text/plain', 0, P2pHash().finish())];
      for (var i = 0; i < 4; i++) {
        service.transfers.add(
          P2pTransfer(
            id: p2pId(),
            roomId: '!room:local',
            peer: '@peer:local',
            outgoing: true,
            files: files,
            expires: DateTime.now().millisecondsSinceEpoch + 60000,
          ),
        );
      }
      var reads = 0;
      await expectLater(
        service.send(
          ['@peer:local'],
          [
            PickedFile(
              name: 'x',
              mime: 'text/plain',
              size: 1,
              read: (_, __) async {
                reads++;
                return Uint8List(1);
              },
              release: () async {},
            ),
          ],
        ),
        throwsA(anything),
      );
      expect(reads, 0);
      expect(client.sent, isEmpty);
    },
  );
}
