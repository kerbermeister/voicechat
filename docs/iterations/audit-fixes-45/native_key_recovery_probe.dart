// Native LiveKit laboratory; no Matrix authorization or app group UI claim.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

Future<void> until(Future<bool> Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 25));
  while (!await condition()) {
    if (DateTime.now().isAfter(end))
      throw TimeoutException('QA media assertion');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Three native E2EE peers, late join, republish and creator leave',
    (tester) async {
      await tester.runAsync(() async {
        const key = String.fromEnvironment('QA_GROUP_KEY');
        expect(key, isNotEmpty);
        final options = <lk.E2EEOptions>[];
        final rooms = <lk.Room>[];
        final retiredRooms = <lk.Room>[];
        final listeners = <lk.EventsListener<lk.RoomEvent>>[];
        final videos = <int, lk.RemoteVideoTrack>{};
        final audios = <int, lk.RemoteAudioTrack>{};
        final ok = <String>{};
        final states = <String>[];
        try {
          for (var i = 0; i < 3; i++) {
            final provider = await lk.BaseKeyProvider.create(ratchetWindowSize: const int.fromEnvironment('QA_RATCHET_WINDOW', defaultValue: 16));
            await provider.setSharedKey(key);
            final encryption = lk.E2EEOptions(keyProvider: provider);
            options.add(encryption);
            final room = lk.Room(
              roomOptions: lk.RoomOptions(encryption: encryption),
            );
            rooms.add(room);
            final events = room.createListener();
            listeners.add(events);
            events.on<lk.TrackSubscribedEvent>((event) {
              if (event.track is lk.RemoteAudioTrack)
                audios[i] = event.track as lk.RemoteAudioTrack;
              if (event.track is lk.RemoteVideoTrack)
                videos[i] = event.track as lk.RemoteVideoTrack;
            });
            events.on<lk.TrackE2EEStateEvent>((event) {
              if (i == 2) states.add(event.state.name);
              if (event.state == lk.E2EEState.kOk)
                ok.add('$i:${event.publication.kind.name}');
            });
          }
          const tokens = [
            String.fromEnvironment('QA_GROUP_A'),
            String.fromEnvironment('QA_GROUP_B'),
            String.fromEnvironment('QA_GROUP_C'),
          ];
          for (var i = 0; i < 2; i++) {
            await rooms[i].connect('ws://127.0.0.1:17880', tokens[i]);
          }
          final audio = await lk.LocalAudioTrack.create();
          audio.mediaStreamTrack.enabled =
              false; // Publish silence to prevent acoustic feedback.
          await rooms[0].localParticipant!.publishAudioTrack(audio);
          await rooms[0].localParticipant!.setCameraEnabled(true);
          Future<void> advancing(int i) async {
            await until(() async => videos[i] != null);
            final track = videos[i]!;
            final start = (await track.getReceiverStats())?.framesDecoded ?? 0;
            await until(
              () async =>
                  ((await track.getReceiverStats())?.framesDecoded ?? 0) >
                  start + 3,
            );
            expect(
              (await track.getReceiverStats())!.frameWidth,
              greaterThan(0),
            );
          }

          await advancing(1);
          await rooms[2].connect('ws://127.0.0.1:17880', tokens[2]);
          await advancing(2);
          await until(
            () async => ok.contains('1:VIDEO') && ok.contains('2:VIDEO'),
          );
          await until(
            () async =>
                ok.contains('1:AUDIO') &&
                ok.contains('2:AUDIO') &&
                audios.length == 2,
          );
          for (final i in [1, 2]) {
            final before =
                (await audios[i]!.getReceiverStats())?.packetsReceived ?? 0;
            await until(
              () async =>
                  ((await audios[i]!.getReceiverStats())?.packetsReceived ??
                      0) >
                  before,
            );
          }
          print(
            'QA_GROUP both audio receivers GCM kOk and RTP increases; source silent PASS',
          );
          print(
            'QA_GROUP two receivers decode encrypted video; third joined late PASS',
          );
          await rooms[0].localParticipant!.setCameraEnabled(false);
          await rooms[0].localParticipant!.setCameraEnabled(true);
          await advancing(1);
          await advancing(2);
          print('QA_GROUP camera off/on and both receivers decode PASS');
          await options[2].keyProvider.setKey(
            'wrong-key-only-in-isolated-QA-room',
          );
          await Future<void>.delayed(const Duration(seconds: 2));
          final frozen = (await videos[2]!.getReceiverStats())?.framesDecoded;
          await advancing(1);
          await Future<void>.delayed(const Duration(seconds: 2));
          expect((await videos[2]!.getReceiverStats())?.framesDecoded, frozen);
          print('QA_GROUP wrong key freezes only C while B decodes PASS');
          states.clear();
          await options[2].keyProvider.setKey(key);
          final restoredNative = await options[2].keyProvider.exportSharedKey();
          expect(restoredNative, key.codeUnits);
          final beforeRestore = await videos[2]!.getReceiverStats();
          await Future<void>.delayed(const Duration(seconds: 26));
          final afterRestore = await videos[2]!.getReceiverStats();
          final participantKey = await options[2].keyProvider.keyProvider.exportKey(participantId: 'qa-a', index: 0);
          print('QA_KEY_PARTICIPANT matchesRestored=${participantKey.length == key.length && List.generate(key.length, (i) => participantKey[i] == key.codeUnitAt(i)).every((v) => v)} ratchetWindow=${const int.fromEnvironment('QA_RATCHET_WINDOW', defaultValue: 16)}');
          print('QA_KEY_RESTORE nativeKeyMatches=true framesBefore=${beforeRestore?.framesDecoded} framesAfter=${afterRestore?.framesDecoded} receivedBefore=${beforeRestore?.framesReceived} receivedAfter=${afterRestore?.framesReceived} states=$states');
          // Distinguish a stale key/cryptor from waiting for a decodable keyframe.
          await rooms[0].localParticipant!.setCameraEnabled(false);
          await rooms[0].localParticipant!.setCameraEnabled(true);
          try {
            await advancing(2);
            print('QA_KEY_RESTORE publisher republish recovers correct key PASS');
          } on TimeoutException {
            print('QA_KEY_RESTORE publisher republish did not recover receiver');
          }
          // In the exploratory run a bare setKey did not resume decoding in 25s.
          // Reconnect recreates the receiver cryptors; this is not app key exchange.
          await rooms[2].disconnect();
          videos.remove(2);
          audios.remove(2);
          retiredRooms.add(rooms[2]);
          final fresh = lk.Room(
            roomOptions: lk.RoomOptions(
              encryption: await lk.E2EEOptions.sharedKey(key),
            ),
          );
          rooms[2] = fresh;
          final freshEvents = fresh.createListener();
          listeners.add(freshEvents);
          freshEvents.on<lk.TrackSubscribedEvent>((event) {
            if (event.track is lk.RemoteVideoTrack)
              videos[2] = event.track as lk.RemoteVideoTrack;
            if (event.track is lk.RemoteAudioTrack)
              audios[2] = event.track as lk.RemoteAudioTrack;
          });
          await rooms[2].connect('ws://127.0.0.1:17880', tokens[2]);
          await advancing(2);
          print('QA_GROUP C reconnect with correct key resumes decoding PASS');
          await rooms[0].disconnect();
          await until(
            () async =>
                rooms[1].remoteParticipants.length == 1 &&
                rooms[2].remoteParticipants.length == 1,
          );
          expect(rooms[1].connectionState, lk.ConnectionState.connected);
          expect(rooms[2].connectionState, lk.ConnectionState.connected);
          videos.remove(2);
          await rooms[1].localParticipant!.setCameraEnabled(true);
          await advancing(2);
          print(
            'QA_GROUP creator leaves; remaining pair and new sender video PASS',
          );
        } finally {
          for (final listener in listeners) {
            await listener.dispose();
          }
          for (final room in [...rooms, ...retiredRooms]) {
            await room.dispose();
          }
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
