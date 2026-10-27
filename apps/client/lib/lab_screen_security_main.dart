// Disposable SS-10/SS-11/SS-15 target. Never distribute this command bridge.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart' as mx;
// SS-11 deliberately bypasses public publish helpers to test server authorization.
// ignore: implementation_imports
import 'package:livekit_client/src/proto/livekit_models.pb.dart' as models;
// ignore: implementation_imports
import 'package:livekit_client/src/proto/livekit_rtc.pb.dart' as signal;
import 'matrix_probe.dart';
import 'call_probe.dart';
import 'call_quality.dart';
import 'call_video_grid.dart';
import 'screen_api.dart';
import 'screen_controller.dart';
import 'screen_panel.dart';

SemanticsHandle? semantics;
final revision = ValueNotifier(0);
MatrixProbe? probe;
CallProbe? call;
ScreenShareController? screen;
Map<String, dynamic> fixture = {};
final envelopes = <Map<String, dynamic>>[];
final rawRooms = <lk.Room>[];
final received = <String>[];
final manual = Object();
bool withhold = false;
int dropped = 0;
String stage = 'loading';
String step = 'idle';
String get livekitUrl => fixture['livekit'] as String? ?? 'ws://localhost:7880';

class KeyGate extends http.BaseClient {
  final http.Client inner;
  KeyGate(this.inner);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (withhold &&
        Zone.current[manual] != true &&
        request.url.path.contains('/sendToDevice/m.room.encrypted/')) {
      dropped++;
      return Future.value(
        http.StreamedResponse(Stream.value(utf8.encode('{}')), 200),
      );
    }
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

Future<Map<String, dynamic>> command(Map<String, dynamic> data) async {
  final client = probe!.client;
  switch (data['action']) {
    case 'identity':
      return {
        'user': client.userID,
        'device': client.deviceID,
        'fingerprint': client.fingerprintKey,
      };
    case 'trust':
      await verifyDevice(
        client,
        data['user'] as String,
        data['device'] as String,
        data['fingerprint'] as String,
      );
    case 'connect':
      step = 'voice-connect';
      final room = await probe!.room(fixture['room'] as String);
      call = CallProbe(
        chat: room,
        session: fixture['session'] as String,
        tokenUrl: fixture['api'] as String,
        livekitUrl: livekitUrl,
        video: true,
        status: (_) {},
        changed: () => revision.value++,
      )..videoQuality = VideoQuality.low;
      revision.value++;
      await call!.connect();
      if (data['screen'] == false) break;
      step = 'screen-bind';
      final api = ScreenApi(
        fixture['api'] as String,
        () => client.accessToken!,
      );
      if ((await api.request('capabilities'))['screen'] != true) {
        api.close();
        break;
      }
      screen = ScreenShareController(call!, api, livekitUrl);
      screen!.addListener(() => revision.value++);
      await screen!.connect();
    case 'rejoin':
      await screen?.close();
      await call?.close();
      screen = null;
      call = null;
      return command({'action': 'connect'});
    case 'seedData':
      final room = await probe!.room(fixture['room'] as String);
      final nonce = data['nonce'] as String;
      final text = await MatrixProbe.sendText(room, 'restore-text:$nonce');
      final file = await room.sendFileEvent(
        mx.MatrixFile(
          bytes: Uint8List.fromList(utf8.encode('restore-file:$nonce')),
          name: 'restore-fixture.txt',
          mimeType: 'text/plain',
        ),
      );
      return {'text': text, 'file': file};
    case 'readData':
      final room = await probe!.room(fixture['room'] as String);
      Future<mx.Event> read(String id) async {
        // Force a server read; a local timeline entry is not restore evidence.
        final wire = await client.getOneRoomEvent(room.id, id);
        if (wire.type != mx.EventTypes.Encrypted) {
          throw StateError('Plaintext event');
        }
        return client.encryption!.decryptRoomEvent(
          mx.Event.fromMatrixEvent(wire, room),
        );
      }
      final text = await read(data['text'] as String);
      final event = await read(data['file'] as String);
      final file = await event.downloadAndDecryptAttachment(skipScanner: true);
      return {
        'text_matches': text.content['body'] == 'restore-text:${data['nonce']}',
        'file_matches':
            utf8.decode(file.bytes) == 'restore-file:${data['nonce']}',
      };
    case 'gate':
      withhold = data['enabled'] == true;
    case 'inspect':
      var frames = 0;
      for (final peer
          in screen?.media?.remoteParticipants.values ??
              <lk.RemoteParticipant>[]) {
        for (final publication in peer.videoTrackPublications) {
          for (final stat
              in await publication.track?.receiver?.getStats() ?? []) {
            if (stat.type == 'inbound-rtp') {
              frames += (stat.values['framesDecoded'] as num? ?? 0).toInt();
            }
          }
        }
      }
      return {
        'frames': frames,
        'decoded': screen?.decoded,
        'received': received,
        'dropped': dropped,
        'generation': screen?.snapshot?.generation,
      };
    case 'currentEnvelope':
      final s = screen!.snapshot!;
      return {
        'protocol_version': 1,
        'room_id': call!.chat.id,
        'call_session': call!.session,
        'binding_id': s.binding,
        'screen_generation': s.generation,
        'revision': s.revision,
        'roster_version': s.rosterVersion,
        'sender_identity': s.owner,
        'sender_device': client.deviceID,
        'expires_at': DateTime.now().millisecondsSinceEpoch + 20000,
        'provider_id': screen!.media!.e2eeManager!.keyProvider.keyProvider.id,
      };
    case 'provider':
      final channel = data['channel'] as String;
      final room = channel == 'screen' ? screen!.media! : call!.media!;
      return {
        'id': room.e2eeManager!.keyProvider.keyProvider.id,
        'generation': room.name,
        'connected': room.connectionState == lk.ConnectionState.connected,
      };
    case 'engineToken':
      // ignore: invalid_use_of_internal_member
      return {'token': screen!.media!.engine.token};
    case 'rawJoin':
      final room = lk.Room();
      try {
        await room.connect(livekitUrl, data['token'] as String);
        return {'connected': true};
      } on lk.ConnectException {
        return {'connected': false};
      } finally {
        await room.dispose();
      }
    case 'signal':
      final room = data['channel'] == 'voice' ? call!.media! : screen!.media!;
      try {
        // Bypass LocalParticipant helpers: test the actual SFU signaling grant.
        // ignore: invalid_use_of_internal_member
        await room.engine.addTrack(
          signal.AddTrackRequest(
            cid: 'negative-${DateTime.now().microsecondsSinceEpoch}',
            name: 'disposable-security-track',
            type: models.TrackType.VIDEO,
            source: data['source'] == 'camera'
                ? models.TrackSource.CAMERA
                : models.TrackSource.SCREEN_SHARE,
            encryption: models.Encryption_Type.GCM,
          ),
        );
        return {'published': true};
      } on lk.TrackPublishException {
        return {'published': false};
      }
    case 'attack':
      final room = screen!.media!, local = screen!.media!.localParticipant!;
      final original =
          local.videoTrackPublications.single.track as lk.LocalVideoTrack;
      final stream = await original.mediaStream.clone();
      // ignore: invalid_use_of_internal_member
      final track = lk.LocalVideoTrack(
        lk.TrackSource.screenShareVideo,
        stream,
        stream.getVideoTracks().single,
        original.currentOptions,
      );
      if (data['kind'] == 'plaintext') {
        // A raw client has no cryptor. Disabling the protected room's cryptor
        // would discard frames instead of producing a real plaintext publication.
        await room.disconnect();
        final raw = lk.Room();
        rawRooms.add(raw);
        await raw.connect(livekitUrl, data['token'] as String);
        await raw.localParticipant!.publishVideoTrack(track);
        return {'published': true};
      }
      try {
        await local.publishVideoTrack(track);
        return {'published': true};
      } catch (_) {
        await track.dispose();
        return {'published': false};
      }
    case 'envelope':
      return Map.from(
        envelopes.lastWhere(
          (e) => e['screen_generation'] == data['generation'],
        ),
      );
    case 'send':
      await refreshDevices(client, {data['user'] as String});
      final device =
          client.userDeviceKeys[data['user']]!.deviceKeys[data['device']]!;
      await runZoned(
        () => client.sendToDeviceEncrypted(
          [device],
          data['type'] as String,
          Map<String, dynamic>.from(data['content'] as Map),
        ),
        zoneValues: {manual: true},
      );
    case 'close':
      for (final room in rawRooms) {
        await room.dispose();
      }
      await screen?.close();
      await call?.close();
      await probe?.close();
  }
  revision.value++;
  return {
    'ok': true,
    'dropped': dropped,
    'generation': screen?.snapshot?.generation,
    'decoded': screen?.decoded,
    'received_generations': envelopes
        .map((e) => e['screen_generation'])
        .toList(),
  };
}

Future<void> prepare() async {
  try {
    fixture =
        jsonDecode((await http.get(Uri.base.resolve('fixture.json'))).body)
            as Map<String, dynamic>;
    probe = await MatrixProbe.open(
      fixture['profile'] as String,
      passphrase: 'disposable-screen-security-vault',
    );
    probe!.client.httpClient = KeyGate(probe!.client.httpClient);
    await probe!.login(
      fixture['matrix'] as String? ?? 'http://localhost:8008',
      fixture['username'] as String,
      fixture['password'] as String,
    );
    await probe!.client.joinRoom(fixture['room'] as String);
    probe!.client.onToDeviceEvent.stream.listen((event) {
      if (event.content['lab_case'] is String) {
        received.add(event.content['lab_case'] as String);
      }
      if (event.type == 'dev.voicechat.screen_key.v1' &&
          event.encryptedContent != null) {
        envelopes.add(Map.from(event.content));
      }
    });
    globalContext.setProperty(
      'screenLab'.toJS,
      ((JSAny raw) {
        return (() async {
          try {
            return (await command(
              Map<String, dynamic>.from(raw.dartify() as Map),
            )).jsify();
          } catch (error) {
            // No SDK exception, credentials, key or JWT in DOM/console/reports.
            return {
              'error': 'lab-command-failed',
              'kind': error.runtimeType.toString(),
              'state': error is StateError
                  ? const [
                          'No element',
                          'Too many elements',
                          'Call closed during authorization',
                          'Call closed during admission',
                          'Device authorization refresh failed',
                          'Call requires an encrypted Matrix room',
                          'Call closed during key provider creation',
                          'E2EE unavailable; refusing microphone',
                          'Call ended during camera permission',
                          'ReusableCompleter disposed',
                          'Cannot add new events after calling close',
                          'Future already completed',
                        ].contains(error.message)
                        ? error.message
                        : 'other'
                  : null,
              'step': step,
            }.jsify();
          }
        })().toJS;
      }).toJS,
    );
    stage = 'ready';
  } catch (_) {
    stage = 'failed';
  }
  revision.value++;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  semantics = SemanticsBinding.instance.ensureSemantics();
  runApp(
    MaterialApp(
      home: ValueListenableBuilder(
        valueListenable: revision,
        builder: (context, _, _) => Scaffold(
          body: Column(
            children: [
              Text(stage),
              if (screen != null) ScreenPanel(controller: screen!),
              if (call != null)
                SizedBox(height: 180, child: CallVideoGrid(call: call!)),
            ],
          ),
        ),
      ),
    ),
  );
  unawaited(prepare());
}
