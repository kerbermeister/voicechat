import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/call_controller.dart';
import 'package:voicechat_probe/voice_recording.dart';

class OutboxDatabase implements MatrixSdkDatabase {
  final values = <String, Map<String, Object?>>{};
  bool failWrite = false;
  @override
  Future<Map<String, BasicEvent>> getAccountData() async => values.map(
    (key, value) => MapEntry(key, BasicEvent(type: key, content: value)),
  );
  @override
  Future<void> storeAccountData(
    String type,
    Map<String, Object?> content,
  ) async {
    if (failWrite) throw StateError('Disk unavailable');
    values[type] = Map<String, Object?>.from(
      jsonDecode(jsonEncode(content)) as Map,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class OutboxRoom implements Room {
  @override
  final Client client;
  @override
  final bool encrypted;
  OutboxRoom(this.client, {this.encrypted = true});
  @override
  String get id => '!test:local';
  @override
  Membership get membership => Membership.join;
  @override
  bool get isDirectChat => false;
  @override
  final receiptState = LatestReceiptState.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class OutboxTimeline implements Timeline {
  @override
  final List<Event> events;
  OutboxTimeline(this.events);
  @override
  final aggregatedEvents = <String, Map<String, Set<Event>>>{};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class VideoSession implements CallSession {
  bool rejected = false;
  @override
  CallType get type => CallType.kVideo;
  @override
  Future<void> hangup({
    required CallErrorCode reason,
    bool shouldEmit = true,
  }) async {
    rejected = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RotatingTurnClient extends Client {
  int requests = 0;
  RotatingTurnClient() : super('turn-test', database: OutboxDatabase());
  @override
  Future<TurnServerCredentials> getTurnServer() async => TurnServerCredentials(
    username: 'call-${++requests}',
    password: 'test-only',
    ttl: 1,
    uris: [Uri.parse('turn:localhost:3478')],
  );
}

class WaitingClient extends Client {
  final token = Completer<TokenOwnerInfo>();
  late Room room;
  WaitingClient(MatrixSdkDatabase database)
    : super('waiting-test', database: database);
  @override
  Room? getRoomById(String id) => room;
  @override
  Future<TokenOwnerInfo> getTokenOwner() => token.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Event'),
        (_) async => null,
      );
  late OutboxDatabase database;
  late Client client;
  setUp(() {
    database = OutboxDatabase();
    client = Client(
      'outbox-test',
      database: database,
      httpClient: MockClient((_) async => http.Response('{}', 503)),
      logLevel: Level.error,
    );
  });
  test(
    'Offline queue survives restart with the same transaction ID; cancellation persists',
    () async {
      final first = ChatActions(client);
      await first.open();
      await first.text(OutboxRoom(client), 'offline text');
      final id = first.pending.single['id'] as String;
      await first.flush();
      await first.close();
      final second = ChatActions(client);
      await second.open();
      expect(second.pending.single['content']['body'], 'offline text');
      expect(second.pending.single['id'], id);
      await second.flush();
      await second.close();
      final third = ChatActions(client);
      await third.open();
      await third.flush();
      // The fake client has no homeserver, so authorization fails before sending.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await third.cancel(id);
      await third.close();
      final fourth = ChatActions(client);
      await fourth.open();
      expect(fourth.pending, isEmpty);
      await fourth.close();
    },
  );
  test(
    'Closing an offline queue does not wait for a stalled request or erase its item',
    () async {
      final waiting = WaitingClient(database);
      waiting.room = OutboxRoom(waiting);
      final actions = ChatActions(waiting);
      await actions.open();
      await actions.text(waiting.room, 'durable before lock');
      await actions.close().timeout(const Duration(seconds: 1));
      waiting.token.complete(TokenOwnerInfo(userId: '@owner:local'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        (database.values.values.single['items'] as List)
            .single['content']['body'],
        'durable before lock',
      );
    },
  );
  test(
    'Reject plaintext, oversized attachments and failed durable writes',
    () async {
      final actions = ChatActions(client);
      await actions.open();
      await expectLater(
        actions.text(OutboxRoom(client, encrypted: false), 'secret'),
        throwsStateError,
      );
      await expectLater(
        actions.attachment(
          OutboxRoom(client),
          MatrixAudioFile(
            bytes: Uint8List(maxAttachmentBytes + 1),
            name: 'large.wav',
          ),
        ),
        throwsStateError,
      );
      database.failWrite = true;
      await expectLater(
        actions.text(OutboxRoom(client), 'not saved'),
        throwsStateError,
      );
      expect(actions.pending, isEmpty);
      database.failWrite = false;
      await actions.text(OutboxRoom(client), 'saved after disk recovers');
      await actions.close();
      expect(database.values.values.single['items'], isNotEmpty);
    },
  );
  test(
    'Read receipts acknowledge older messages without acknowledging newer ones',
    () {
      final room = OutboxRoom(client);
      Event event(String id) => Event(
        senderId: '@writer:local',
        eventId: id,
        type: EventTypes.Message,
        content: {'body': id, 'msgtype': MessageTypes.Text},
        room: room,
        originServerTs: DateTime.now(),
      );
      final newer = event('newer');
      final older = event('older');
      final timeline = OutboxTimeline([newer, older]);
      room.receiptState.global.otherUsers['@reader:local'] =
          LatestReceiptStateData('older', 0);
      expect(messageIsRead(older, timeline), true);
      expect(messageIsRead(newer, timeline), false);
      room.receiptState.global.otherUsers['@reader:local'] =
          LatestReceiptStateData('newer', 0);
      expect(messageIsRead(older, timeline), true);
      room.receiptState.global.otherUsers['@reader:local'] =
          LatestReceiptStateData('unknown', 0);
      expect(messageIsRead(older, timeline), false);
    },
  );
  test('Voice WAV describes exactly the PCM bytes and enforces bounds', () {
    final pcm = Uint8List.fromList([0, 0, 255, 127]);
    final wav = voiceWav(pcm);
    final header = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(header.getUint32(24, Endian.little), 16000);
    expect(header.getUint32(40, Endian.little), pcm.length);
    expect(wav.sublist(44), pcm);
    expect(() => voiceWav(Uint8List(0)), throwsArgumentError);
    expect(() => voiceWav(Uint8List(3)), throwsArgumentError);
    expect(() => voiceWav(Uint8List(16000 * 2 * 180 + 2)), throwsArgumentError);
  });
  test('Each call obtains fresh expiring TURN credentials', () async {
    final turnClient = RotatingTurnClient();
    final calls = CallController(
      turnClient,
      'http://localhost:8090',
      'ws://localhost:7880',
      (_) {},
    );
    final first = await calls.voip.getIceServers();
    final second = await calls.voip.getIceServers();
    expect(first.single['username'], isNot(second.single['username']));
    expect(turnClient.requests, 2);
    await calls.close();
  });
  test(
    'Video offers are refused before creating media or requesting the camera',
    () async {
      final calls = CallController(
        client,
        'http://localhost:8090',
        'ws://localhost:7880',
        (_) {},
      );
      final video = VideoSession();
      await calls.registerListeners(video);
      expect(video.rejected, true);
      expect(calls.active, isNull);
      await calls.close();
    },
  );
  test(
    'Call invitations reject malformed, stale and unrelated cancellation',
    () async {
      final calls = CallController(
        client,
        'http://localhost:8090',
        'ws://localhost:7880',
        (_) {},
      );
      Event event(
        String sender,
        Map<String, dynamic> content, {
        DateTime? timestamp,
      }) => Event(
        senderId: sender,
        eventId: '\$test',
        type: EventTypes.Message,
        content: content,
        room: OutboxRoom(client),
        originServerTs: timestamp ?? DateTime.now(),
      );
      const id = '0123456789abcdef0123456789abcdef';
      calls.receive(
        event('@alice:local', {
          'msgtype': 'dev.voicechat.call',
          'action': 'invite',
          'session': 'bad',
        }),
      );
      calls.receive(
        event('@alice:local', {
          'msgtype': 'dev.voicechat.call',
          'action': 'invite',
          'session': id,
        }, timestamp: DateTime.now().subtract(const Duration(minutes: 11))),
      );
      expect(calls.invitations, isEmpty);
      calls.receive(
        event('@alice:local', {
          'msgtype': 'dev.voicechat.call',
          'action': 'invite',
          'session': id,
        }),
      );
      expect(calls.invitations, hasLength(1));
      calls.receive(
        event('@mallory:local', {
          'msgtype': 'dev.voicechat.call',
          'action': 'end',
          'session': id,
        }),
      );
      expect(calls.invitations, hasLength(1));
      calls.receive(
        event('@alice:local', {
          'msgtype': 'dev.voicechat.call',
          'action': 'end',
          'session': id,
        }),
      );
      expect(calls.invitations, isEmpty);
      await calls.close();
    },
  );
}
