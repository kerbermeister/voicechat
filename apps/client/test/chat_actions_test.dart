import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/utils/cached_stream_controller.dart';
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/media_policy.dart';
import 'package:voicechat_probe/call_controller.dart';
import 'package:voicechat_probe/voice_recording.dart';
import 'message_test.dart' show TestClient;

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
  @override
  final roomAccountData = <String, BasicEvent>{};
  @override
  StrippedStateEvent? getState(String type, [String stateKey = '']) => null;
  OutboxRoom(this.client, {this.encrypted = true});
  @override
  String get id => '!test:local';
  @override
  Membership get membership => Membership.join;
  @override
  bool get isDirectChat => false;
  @override
  HistoryVisibility get historyVisibility => HistoryVisibility.joined;
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
  WrappedMediaStream? get localUserMediaStream => null;
  @override
  WrappedMediaStream? get remoteUserMediaStream => null;
  @override
  List<WrappedMediaStream> get getLocalStreams => [];
  @override
  List<WrappedMediaStream> get getRemoteStreams => [];
  @override
  CallType get type => CallType.kVideo;
  @override
  CallDirection get direction => CallDirection.kOutgoing;
  @override
  String get callId => 'video-test';
  @override
  CallState get state => CallState.kInviteSent;
  @override
  final onCallStateChanged = CachedStreamController<CallState>();
  @override
  final onCallStreamsChanged = CachedStreamController<CallSession>();
  @override
  final onStreamAdd = CachedStreamController<WrappedMediaStream>();
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

class BackgroundStream implements WrappedMediaStream {
  @override
  final stream = BackgroundMediaStream();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class BackgroundMediaStream implements rtc.MediaStream {
  @override
  List<rtc.MediaStreamTrack> getAudioTracks() => [BackgroundAudioTrack()];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class BackgroundAudioTrack implements rtc.MediaStreamTrack {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class BackgroundRoom extends OutboxRoom {
  BackgroundRoom(super.client);
  @override
  bool get isDirectChat => true;
}

class BackgroundSession extends VideoSession {
  @override
  final Room room;
  BackgroundSession(this.room);
  @override
  WrappedMediaStream? localUserMediaStream;
}

class IndependentQueueClient extends Client {
  int attempts = 0;
  late final room = OutboxRoom(this);
  IndependentQueueClient(super.clientName, {required super.database});
  @override
  Room? getRoomById(String id) => room;
  @override
  Future<TokenOwnerInfo> getTokenOwner() async {
    attempts++;
    throw StateError('Authorization unavailable');
  }
}

class SendingQueueClient extends TestClient {
  @override
  final database = OutboxDatabase();
  final roomsById = <String, SendingQueueRoom>{};
  @override
  Room? getRoomById(String id) => roomsById[id];
}

class SendingQueueRoom extends OutboxRoom {
  final String roomId;
  final Completer<String?>? gate;
  final sent = <String>[];
  Object? failure;
  SendingQueueRoom(super.client, this.roomId, {this.gate});
  @override
  String get id => roomId;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #requestParticipants) {
      return Future.value(<User>[]);
    }
    if (invocation.memberName == #sendEvent ||
        invocation.memberName == #sendFileEvent) {
      sent.add(invocation.namedArguments[#txid] as String);
      if (failure != null) return Future<String?>.error(failure!);
      return sent.length == 1 && gate != null
          ? gate!.future
          : Future<String?>.value('event-${sent.length}');
    }
    return super.noSuchMethod(invocation);
  }
}

class PolicyQueueClient extends SendingQueueClient {
  bool available = false, valid = true;
  @override
  http.Client get httpClient => _policyHttp;
  late final _policyHttp = MockClient(
    (_) async => http.Response(
      jsonEncode(valid ? const MediaPolicy().toJson() : {}),
      available ? 200 : 503,
    ),
  );
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
  test(
    'Media volume persists locally per chat; serial writes and failures preserve values',
    () async {
      final db = OutboxDatabase();
      final client = Client('media-volume', database: db);
      final actions = ChatActions(client);
      await actions.open();
      expect(actions.mediaVolume('!one:local'), 1);
      await Future.wait([
        actions.setMediaVolume('!one:local', .3),
        actions.setMediaVolume('!two:local', 0),
      ]);
      db.failWrite = true;
      await expectLater(
        actions.setMediaVolume('!one:local', .9),
        throwsStateError,
      );
      expect(actions.mediaVolume('!one:local'), .3);
      db.failWrite = false;
      await actions.close();
      db.values['dev.voicechat.local.media_volumes']!['!bad:local'] = 3;
      final restored = ChatActions(client);
      await restored.open();
      expect(restored.mediaVolume('!one:local'), .3);
      expect(restored.mediaVolume('!two:local'), 0);
      expect(restored.mediaVolume('!bad:local'), 1);
      expect(
        () => restored.setMediaVolume('!one:local', double.nan),
        throwsArgumentError,
      );
      await restored.close();
      await client.dispose();
    },
  );

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
    'Temporary API outage keeps ordered transactions and recovers without new IDs',
    () async {
      final client = PolicyQueueClient();
      final room = SendingQueueRoom(client, '!temporary:local');
      client.roomsById[room.id] = room;
      final actions = ChatActions(client, policyUrl: 'http://localhost:8090');
      for (final id in ['temporary-id', 'ordinary-id']) {
        actions.pending.add({
          'id': id,
          'room': room.id,
          'type': EventTypes.Message,
          'created': 0,
          'content': {
            'msgtype': MessageTypes.Text,
            'body': id,
            if (id == 'temporary-id') 'dev.voicechat.ttl_seconds': 10,
          },
        });
      }
      await actions.flush();
      expect(room.sent, isEmpty);
      expect(
        actions.pending.first['error'],
        contains('Сервис временных сообщений недоступен'),
      );
      expect(
        actions.pendingStatus(actions.pending.last),
        startsWith('Ожидает отправки предыдущего сообщения.'),
      );
      expect(
        ((client.database as OutboxDatabase)
                    .values['dev.voicechat.local.outbox']!['items']
                as List)
            .length,
        2,
      );
      client.available = true;
      client.valid = false;
      await actions.flush();
      expect(
        room.sent,
        isEmpty,
        reason: 'Invalid policy must not bypass validation',
      );
      client.valid = true;
      await actions.flush();
      expect(room.sent, ['temporary-id', 'ordinary-id']);
      expect(actions.pending, isEmpty);
      await actions.close();
    },
  );

  test(
    'A server rejection is distinguished from a missing acknowledgement',
    () async {
      final client = PolicyQueueClient()..available = true;
      final room = SendingQueueRoom(client, '!rejected:local')
        ..failure = MatrixException.fromJson({'errcode': 'M_FORBIDDEN'});
      client.roomsById[room.id] = room;
      final actions = ChatActions(client, policyUrl: 'http://localhost:8090');
      actions.pending.add({
        'id': 'retained-id',
        'room': room.id,
        'type': EventTypes.Message,
        'created': 0,
        'content': {
          'msgtype': MessageTypes.Text,
          'body': 'temporary',
          'dev.voicechat.ttl_seconds': 10,
        },
      });
      await actions.flush();
      expect(
        actions.pending.single['error'],
        startsWith('Сервер отклонил временное сообщение.'),
      );
      room.failure = null;
      await actions.flush();
      expect(room.sent, ['retained-id', 'retained-id']);
      expect(actions.pending, isEmpty);
      await actions.close();
    },
  );

  test(
    'Slow uploads do not block other chats; messages in one chat stay ordered',
    () async {
      final client = SendingQueueClient();
      final actions = ChatActions(client);
      final gates = [Completer<String?>(), Completer<String?>()];
      Map<String, dynamic> item(String id, String room, {bool audio = false}) =>
          {
            'id': id,
            'room': room,
            'type': EventTypes.Message,
            'created': 0,
            'content': audio
                ? {
                    'msgtype': MessageTypes.Audio,
                    'body': 'voice.wav',
                    'mime': 'audio/wav',
                    'bytes': base64Encode(Uint8List(16)),
                  }
                : {'msgtype': MessageTypes.Text, 'body': id},
          };
      for (var i = 0; i < 2; i++) {
        final id = '!slow$i:local';
        client.roomsById[id] = SendingQueueRoom(client, id, gate: gates[i]);
        actions.pending.add(item('upload$i', id, audio: true));
      }
      actions.pending.add(item('after-upload', '!slow0:local'));
      client.roomsById['!fast:local'] = SendingQueueRoom(client, '!fast:local');
      actions.pending.add(item('fast', '!fast:local'));
      final sending = actions.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.roomsById['!fast:local']!.sent, ['fast']);
      expect(client.roomsById['!slow0:local']!.sent, ['upload0']);
      client.roomsById['!new:local'] = SendingQueueRoom(client, '!new:local');
      actions.pending.add(item('new', '!new:local'));
      await actions.flush();
      expect(client.roomsById['!new:local']!.sent, ['new']);
      for (final gate in gates) {
        gate.complete('upload-event');
      }
      await sending;
      expect(client.roomsById['!slow0:local']!.sent, [
        'upload0',
        'after-upload',
      ]);
      expect(actions.pending, isEmpty);
      await actions.close();
    },
  );
  test(
    'A blocked chat preserves its order without blocking other chats',
    () async {
      final independent = IndependentQueueClient(
        'independent',
        database: database,
      );
      final actions = ChatActions(independent);
      for (final (id, room) in [
        ('one', '!a:local'),
        ('two', '!a:local'),
        ('three', '!b:local'),
      ]) {
        actions.pending.add({
          'id': id,
          'room': room,
          'content': {'body': id},
        });
      }
      await actions.flush();
      expect(independent.attempts, 2);
      expect(actions.pending.map((p) => p['id']), ['one', 'two', 'three']);
      expect(actions.pending[1]['error'], isNull);
      expect(
        actions.pendingStatus(actions.pending[1]),
        startsWith('Ожидает отправки предыдущего сообщения.'),
      );
      expect(actions.pending[2]['error'], isNotNull);
      await actions.close();
    },
  );
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
    'Android background service starts only after microphone capture and stops on close',
    () async {
      const channel = MethodChannel('voicechat/calls');
      final updates = <bool>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'active');
            updates.add(call.arguments as bool);
            return null;
          });
      final calls = CallController(
        client,
        'http://localhost:8090',
        'ws://localhost:7880',
        (_) {},
      );
      final session = BackgroundSession(BackgroundRoom(client));
      await calls.registerListeners(session);
      await calls.handleNewCall(session);
      await Future<void>.delayed(Duration.zero);
      expect(updates, isEmpty);
      session.localUserMediaStream = BackgroundStream();
      session.onCallStateChanged.add(CallState.kConnected);
      await Future<void>.delayed(Duration.zero);
      expect(updates, [true]);
      session.onCallStateChanged.add(CallState.kConnected);
      await Future<void>.delayed(Duration.zero);
      expect(updates, [true]);
      await calls.close();
      expect(updates, [true, false]);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );
  test(
    'Registering a video offer does not request the camera before acceptance',
    () async {
      final calls = CallController(
        client,
        'http://localhost:8090',
        'ws://localhost:7880',
        (_) {},
      );
      final video = VideoSession();
      await calls.registerListeners(video);
      expect(video.rejected, false);
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
      calls.receive(
        event('@alice:local', {
          'msgtype': 'dev.voicechat.call',
          'action': 'invite',
          'session': id,
        }, timestamp: DateTime.now().add(const Duration(minutes: 2))),
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
      for (final action in ['invite', 'end']) {
        calls.receive(
          event('@alice:local', {
            'msgtype': 'dev.voicechat.call',
            'action': action,
            'session': 'fedcba9876543210fedcba9876543210',
          }, timestamp: DateTime.now().add(const Duration(seconds: 30))),
        );
        expect(calls.invitations, hasLength(action == 'invite' ? 1 : 0));
      }
      await calls.close();
    },
  );
}
