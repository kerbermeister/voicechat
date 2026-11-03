// Real loopback GCM probe shared by native and browser-only fixtures.
// No account, signalling service, media recording or external ICE servers.
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

Future<Map<String, Object>> runKeyEpochProbe({
  required Future<rtc.MediaStream> Function() capture,
  Map<String, dynamic> configuration = const {'iceServers': []},
  int initialSlot = 0,
  void Function(rtc.RTCVideoRenderer?)? onRenderer,
}) async {
  void check(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  check(initialSlot >= 0 && initialSlot <= 12, 'Invalid starting key slot');
  final sender = await rtc.createPeerConnection(configuration);
  final receiver = await rtc.createPeerConnection(configuration);
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
    throw StateError('New epoch did not decode after $before frames');
  }

  try {
    final initialKey = key();
    await sendingKeys.setRawKey(
      initialKey,
      participantId: 'sender',
      keyIndex: initialSlot,
    );
    await receivingKeys.setRawKey(
      initialKey,
      participantId: 'sender',
      keyIndex: initialSlot,
    );
    source = await capture();
    final track = await sender.addTrack(source.getVideoTracks().single, source);
    final encryptor = await rtc.frameCryptorFactory
        .createFrameCryptorForRtpSender(
          participantId: 'sender',
          sender: track,
          algorithm: rtc.Algorithm.kAesGcm,
          keyProvider: sendingKeys.keyProvider,
        );
    cryptors.add(encryptor);
    await encryptor.setKeyIndex(initialSlot);
    await encryptor.setEnabled(true);
    await encryptor.updateCodec('vp8');
    await sender.setLocalDescription(await sender.createOffer());
    final offer = (await sender.getLocalDescription())!;
    final trackId = source.getVideoTracks().single.id!;
    // The web worker indexes cryptors by track ID. Give the loopback receiver
    // its own ID, as it would have in a different browser process.
    final remoteSdp = offer.sdp!.replaceAll(
      RegExp(' ${RegExp.escape(trackId)}(?=\\r?\\n)'),
      ' receiver-$trackId',
    );
    check(remoteSdp != offer.sdp, 'Offer has no video msid');
    await receiver.setRemoteDescription(
      rtc.RTCSessionDescription(remoteSdp, offer.type),
    );
    receiverReady = true;
    for (final candidate in offerCandidates) {
      await receiver.addCandidate(candidate);
    }
    final event = await incoming.future.timeout(const Duration(seconds: 10));
    check(
      event.track.id != trackId,
      'Loopback cryptors must use distinct track IDs',
    );
    final decryptor = await rtc.frameCryptorFactory
        .createFrameCryptorForRtpReceiver(
          participantId: 'sender',
          receiver: event.receiver!,
          algorithm: rtc.Algorithm.kAesGcm,
          keyProvider: receivingKeys.keyProvider,
        );
    cryptors.add(decryptor);
    await decryptor.setKeyIndex(initialSlot);
    await decryptor.setEnabled(true);
    await decryptor.updateCodec('vp8');
    await view.initialize();
    view.srcObject = event.streams.single;
    // Browser autoplay; native mute controls only a local microphone track.
    if (kIsWeb) view.muted = true;
    onRenderer?.call(view);
    await receiver.setLocalDescription(await receiver.createAnswer());
    await sender.setRemoteDescription((await receiver.getLocalDescription())!);
    senderReady = true;
    for (final candidate in answerCandidates) {
      await sender.addCandidate(candidate);
    }
    final initialFrames = await decodedAfter(0);

    // Preparing a future slot must leave current media on the old key.
    // The SDK's cached latest index already advances here, so an epoch
    // protocol must pin newly published senders until recipients ACK.
    final preparedKey = key();
    await sendingKeys.setRawKey(
      preparedKey,
      participantId: 'sender',
      keyIndex: initialSlot + 1,
    );
    await receivingKeys.setRawKey(
      preparedKey,
      participantId: 'sender',
      keyIndex: initialSlot + 1,
    );
    check(
      sendingKeys.getLatestIndex('sender') == initialSlot + 1,
      'SDK latest index did not advance',
    );
    check(
      await encryptor.keyIndex == initialSlot,
      'Sender switched before commit',
    );
    final preparedFrames = await decodedAfter(initialFrames);
    await decryptor.setKeyIndex(initialSlot + 1);
    final olderFrames = await decodedAfter(preparedFrames);
    check(
      await encryptor.keyIndex == initialSlot,
      'Sender switched before commit',
    );
    await encryptor.setKeyIndex(initialSlot + 1);
    final activatedFrames = await decodedAfter(olderFrames);

    // A receiver holding only the old epoch must not decode the new one.
    final secondKey = key();
    await sendingKeys.setRawKey(
      secondKey,
      participantId: 'sender',
      keyIndex: initialSlot + 2,
    );
    await encryptor.setKeyIndex(initialSlot + 2);
    await Future<void>.delayed(const Duration(seconds: 2));
    final blocked = await frames(receiver, 'framesDecoded');
    final encoded = await frames(sender, 'framesEncoded');
    await Future<void>.delayed(const Duration(seconds: 3));
    check(
      await frames(receiver, 'framesDecoded') == blocked,
      'Unknown epoch was decoded',
    );
    check(
      await frames(sender, 'framesEncoded') > encoded,
      'Sender stopped encoding during unknown-key probe',
    );

    await receivingKeys.setRawKey(
      secondKey,
      participantId: 'sender',
      keyIndex: initialSlot + 2,
    );
    await decryptor.setKeyIndex(initialSlot + 2);
    final recovered = await decodedAfter(blocked);
    final thirdKey = key();
    await receivingKeys.setRawKey(
      thirdKey,
      participantId: 'sender',
      keyIndex: initialSlot + 3,
    );
    await sendingKeys.setRawKey(
      thirdKey,
      participantId: 'sender',
      keyIndex: initialSlot + 3,
    );
    await decryptor.setKeyIndex(initialSlot + 3);
    await encryptor.setKeyIndex(initialSlot + 3);
    final thirdFrames = await decodedAfter(recovered);
    var latestFrames = thirdFrames;
    for (var epoch = initialSlot + 4; epoch < 16; epoch++) {
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
    check(
      receiver.connectionState ==
          rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      'Peer disconnected during key rotation',
    );
    final disposedCommands = <String, bool>{};
    if (kIsWeb) {
      final previousIndex = await decryptor.keyIndex;
      await decryptor.dispose();
      cryptors.remove(decryptor);
      var indexRejected = false, enableRejected = false;
      try {
        indexRejected = !(await decryptor.setKeyIndex(initialSlot));
      } catch (_) {
        indexRejected = true;
      }
      try {
        enableRejected = !(await decryptor.setEnabled(true));
      } catch (_) {
        enableRejected = true;
      }
      disposedCommands.addAll({
        'index_rejected': indexRejected,
        'index_cache_preserved': await decryptor.keyIndex == previousIndex,
        'enable_rejected': enableRejected,
        'enable_cache_preserved': !(await decryptor.enabled),
      });
      check(
        disposedCommands.values.every((value) => value),
        'Disposed cryptor reported successful state changes: $disposedCommands',
      );
    }
    // No SDP/ICE restart, new track, cryptor or receiver was created above.
    return {
      if (disposedCommands.isNotEmpty) 'disposed_commands': disposedCommands,
      'initial_frames': initialFrames,
      'frames_while_future_key_prepared': preparedFrames,
      'old_frames_after_receiver_index_advanced': olderFrames,
      'frames_after_prepared_key_activation': activatedFrames,
      'sdk_latest_index_ahead_of_active_sender': true,
      'old_key_blocked': true,
      'frames_after_late_epoch': recovered,
      'frames_after_preinstalled_epoch': thirdFrames,
      'last_frames': latestFrames,
      'initial_slot': initialSlot,
      'distinct_slots_activated': 16 - initialSlot,
      if (initialSlot == 0) 'frames_after_16_distinct_slots': latestFrames,
      'key_slots_reused': false,
      'receiver_recreated': false,
      'ratchet_defaults_changed': false,
      'matrix_membership_protocol_tested': false,
    };
  } finally {
    closed = true;
    onRenderer?.call(null);
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
}
