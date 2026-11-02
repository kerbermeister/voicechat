// Local native SDK probe, no Matrix/SFU/account and no saved camera frames.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:integration_test/integration_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native sender key epochs recover without a new receiver',
    (tester) async {
      await tester.runAsync(() async {
        final sender = await rtc.createPeerConnection({'iceServers': []});
        final receiver = await rtc.createPeerConnection({'iceServers': []});
        final sendingKeys = await lk.BaseKeyProvider.create(
          sharedKey: false,
          discardFrameWhenCryptorNotReady: true,
        );
        final receivingKeys = await lk.BaseKeyProvider.create(
          sharedKey: false,
          discardFrameWhenCryptorNotReady: true,
        );
        final view = rtc.RTCVideoRenderer();
        final cryptors = <rtc.FrameCryptor>[];
        rtc.MediaStream? source;
        final incoming = Completer<rtc.RTCTrackEvent>();
        final offerCandidates = <rtc.RTCIceCandidate>[];
        final answerCandidates = <rtc.RTCIceCandidate>[];
        var senderReady = false, receiverReady = false, closed = false;
        sender.onIceCandidate = (candidate) {
          if (closed || candidate.candidate?.isNotEmpty != true) return;
          if (receiverReady) {
            unawaited(receiver.addCandidate(candidate));
          } else {
            offerCandidates.add(candidate);
          }
        };
        receiver.onIceCandidate = (candidate) {
          if (closed || candidate.candidate?.isNotEmpty != true) return;
          if (senderReady) {
            unawaited(sender.addCandidate(candidate));
          } else {
            answerCandidates.add(candidate);
          }
        };
        receiver.onTrack = (event) {
          if (!incoming.isCompleted) incoming.complete(event);
        };
        final random = Random.secure();
        Uint8List key() =>
            Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
        Future<int> frames(rtc.RTCPeerConnection peer, String field) async {
          final reports = await peer.getStats();
          return reports
              .where(
                (r) =>
                    (r.values['kind'] ?? r.values['mediaType']) == 'video' &&
                    r.values[field] is num,
              )
              .fold<int>(0, (sum, r) => sum + (r.values[field] as num).toInt());
        }

        Future<int> decodedAfter(int before) async {
          final watch = Stopwatch()..start();
          while (watch.elapsed < const Duration(seconds: 15)) {
            final decoded = await frames(receiver, 'framesDecoded');
            if (decoded > before + 5) return decoded;
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          throw StateError('New epoch did not decode');
        }

        try {
          final initialKey = key();
          await sendingKeys.setRawKey(initialKey, participantId: 'sender');
          await receivingKeys.setRawKey(initialKey, participantId: 'sender');
          source = await rtc.navigator.mediaDevices.getUserMedia({
            'audio': false,
            'video': {
              'width': {'ideal': 320},
              'height': {'ideal': 180},
              'frameRate': {'ideal': 15},
            },
          });
          final track = await sender.addTrack(
            source.getVideoTracks().single,
            source,
          );
          final encryptor = await rtc.frameCryptorFactory
              .createFrameCryptorForRtpSender(
                participantId: 'sender',
                sender: track,
                algorithm: rtc.Algorithm.kAesGcm,
                keyProvider: sendingKeys.keyProvider,
              );
          cryptors.add(encryptor);
          await encryptor.setKeyIndex(0);
          await encryptor.setEnabled(true);
          await sender.setLocalDescription(await sender.createOffer());
          await receiver.setRemoteDescription(
            (await sender.getLocalDescription())!,
          );
          receiverReady = true;
          for (final candidate in offerCandidates) {
            await receiver.addCandidate(candidate);
          }
          final event = await incoming.future.timeout(
            const Duration(seconds: 10),
          );
          final decryptor = await rtc.frameCryptorFactory
              .createFrameCryptorForRtpReceiver(
                participantId: 'sender',
                receiver: event.receiver!,
                algorithm: rtc.Algorithm.kAesGcm,
                keyProvider: receivingKeys.keyProvider,
              );
          cryptors.add(decryptor);
          await decryptor.setKeyIndex(0);
          await decryptor.setEnabled(true);
          await view.initialize();
          view.srcObject = event.streams.single;
          await receiver.setLocalDescription(await receiver.createAnswer());
          await sender.setRemoteDescription(
            (await receiver.getLocalDescription())!,
          );
          senderReady = true;
          for (final candidate in answerCandidates) {
            await sender.addCandidate(candidate);
          }
          final initialFrames = await decodedAfter(0);

          // A receiver holding only the old epoch must not decode the new one.
          final secondKey = key();
          await sendingKeys.setRawKey(
            secondKey,
            participantId: 'sender',
            keyIndex: 1,
          );
          await encryptor.setKeyIndex(1);
          await Future<void>.delayed(const Duration(seconds: 2));
          final blocked = await frames(receiver, 'framesDecoded');
          final encoded = await frames(sender, 'framesEncoded');
          await Future<void>.delayed(const Duration(seconds: 3));
          expect(await frames(receiver, 'framesDecoded'), blocked);
          expect(await frames(sender, 'framesEncoded'), greaterThan(encoded));

          await receivingKeys.setRawKey(
            secondKey,
            participantId: 'sender',
            keyIndex: 1,
          );
          await decryptor.setKeyIndex(1);
          final recovered = await decodedAfter(blocked);
          final thirdKey = key();
          await receivingKeys.setRawKey(
            thirdKey,
            participantId: 'sender',
            keyIndex: 2,
          );
          await sendingKeys.setRawKey(
            thirdKey,
            participantId: 'sender',
            keyIndex: 2,
          );
          await decryptor.setKeyIndex(2);
          await encryptor.setKeyIndex(2);
          final thirdFrames = await decodedAfter(recovered);
          var latestFrames = thirdFrames;
          for (var epoch = 3; epoch < 16; epoch++) {
            final nextKey = key();
            await receivingKeys.setRawKey(
              nextKey,
              participantId: 'sender',
              keyIndex: epoch,
            );
            await sendingKeys.setRawKey(
              nextKey,
              participantId: 'sender',
              keyIndex: epoch,
            );
            await decryptor.setKeyIndex(epoch);
            await encryptor.setKeyIndex(epoch);
            latestFrames = await decodedAfter(latestFrames);
          }
          expect(
            receiver.connectionState,
            rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected,
          );
          // No SDP/ICE restart, new track, cryptor or receiver was created above.
          // ignore: avoid_print
          print(
            'KEY_EPOCH_PROOF ${jsonEncode({'initial_frames': initialFrames, 'old_key_blocked': true, 'frames_after_late_epoch': recovered, 'frames_after_preinstalled_epoch': thirdFrames, 'frames_after_16_distinct_slots': latestFrames, 'key_slots_reused': false, 'receiver_recreated': false, 'ratchet_defaults_changed': false, 'matrix_membership_protocol_tested': false})}',
          );
        } finally {
          closed = true;
          sender.onIceCandidate = null;
          receiver.onIceCandidate = null;
          view.srcObject = null;
          for (final cryptor in cryptors.reversed) {
            await cryptor.dispose();
          }
          await sender.close();
          await receiver.close();
          for (final track in source?.getTracks() ?? <rtc.MediaStreamTrack>[]) {
            await track.stop();
          }
          await source?.dispose();
          await view.dispose();
          await sendingKeys.keyProvider.dispose();
          await receivingKeys.keyProvider.dispose();
        }
      });
    },
    skip:
        !Platform.isMacOS || !const bool.fromEnvironment('HARDWARE_CALL_TEST'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
