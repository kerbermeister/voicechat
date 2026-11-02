// Real SDK/SFU probe. Local camera frames stay in memory; no Matrix/account.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:integration_test/integration_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:livekit_client/src/core/engine.dart';

// Candidate for the future epoch protocol, not used by the application.
class _PinnedKeyProvider extends lk.BaseKeyProvider {
  int activeSlot = 0;
  _PinnedKeyProvider(lk.BaseKeyProvider provider)
    : super(provider.keyProvider, provider.options);
  @override
  int getLatestIndex(String participantId) => participantId == 'alice'
      ? activeSlot
      : super.getLatestIndex(participantId);
  int get preparedSlot => super.getLatestIndex('alice');
}

Future<Map<String, Object>> probePublication({required bool pinned}) async {
  const requireEncryption = bool.fromEnvironment(
    'GROUP_TEST_REQUIRE_FRAME_ENCRYPTION',
  );
  lk.Room encryptedRoom(lk.RoomOptions options) => lk.Room(
    roomOptions: options,
    engine: requireEncryption
        ? Engine(
            connectOptions: const lk.ConnectOptions(),
            roomOptions: options,
            peerConnectionCreate:
                (
                  Map<String, dynamic> config, [
                  Map<String, dynamic> constraints = const {},
                ]) => rtc.createPeerConnection({
                  ...config,
                  'cryptoOptions': {
                    ...?config['cryptoOptions'] as Map<String, dynamic>?,
                    'requireFrameEncryption': true,
                  },
                }, constraints),
          )
        : null,
  );
  final raw = await lk.BaseKeyProvider.create(
    sharedKey: false,
    discardFrameWhenCryptorNotReady: true,
  );
  final sendingKeys = pinned ? _PinnedKeyProvider(raw) : raw;
  final receivingKeys = await lk.BaseKeyProvider.create(
    sharedKey: false,
    discardFrameWhenCryptorNotReady: true,
  );
  final alice = encryptedRoom(
    lk.RoomOptions(
      encryption: lk.E2EEOptions(keyProvider: sendingKeys),
      defaultCameraCaptureOptions: const lk.CameraCaptureOptions(
        maxFrameRate: 15,
        params: lk.VideoParameters(dimensions: lk.VideoDimensions(320, 180)),
      ),
      defaultVideoPublishOptions: const lk.VideoPublishOptions(
        simulcast: false,
        videoCodec: 'vp8',
      ),
    ),
  );
  final bob = encryptedRoom(
    lk.RoomOptions(encryption: lk.E2EEOptions(keyProvider: receivingKeys)),
  );
  // An observer without a decryptor must never decode plaintext camera frames.
  final observer = lk.Room();
  const channel = MethodChannel('FlutterWebRTC.Method');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var observingInitial = true, constructorDelayed = false;
  var preCryptorFrames = 0, preCryptorSamples = 0;
  final preCryptorSizes = <String>{};
  Future<void>? sampling;
  Timer? sampler;
  // Forward every RPC to the real native plugin. Delay only the first sender
  // cryptor constructor, while the observer has no decryptor. This distinguishes
  // actual unprotected RTP from a decoder's response to later ciphertext/SIF.
  messenger.setMockMethodCallHandler(channel, (call) async {
    if (observingInitial &&
        call.method == 'frameCryptorFactoryCreateFrameCryptor' &&
        (call.arguments as Map)['type'] == 'sender') {
      constructorDelayed = true;
      await Future<void>.delayed(const Duration(seconds: 1));
      constructorDelayed = false;
    }
    final reply = await messenger.delegate.send(
      channel.name,
      channel.codec.encodeMethodCall(call),
    );
    if (reply == null) {
      throw MissingPluginException('Native WebRTC unavailable');
    }
    return channel.codec.decodeEnvelope(reply);
  });
  final views = <rtc.RTCVideoRenderer>[];
  final renderedSizes = <lk.RemoteVideoTrack, Set<String>>{};
  final random = Random.secure();
  Uint8List key() =>
      Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
  Future<lk.RemoteVideoTrack> remote(lk.Room room, String sid) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(seconds: 15)) {
      final publication = room
          .remoteParticipants['alice']
          ?.videoTrackPublications
          .where((publication) => publication.sid == sid)
          .firstOrNull;
      final track = publication?.track;
      if (track != null) {
        final view = rtc.RTCVideoRenderer();
        final sizes = renderedSizes[track] = <String>{};
        view.onResize = () {
          sizes.add('${view.videoWidth}x${view.videoHeight}');
        };
        await view.initialize();
        view.srcObject = track.mediaStream;
        views.add(view);
        return track;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('SDK did not subscribe to the video publication');
  }

  int count(List<rtc.StatsReport> reports, String field) => reports
      .where((report) => report.values[field] is num)
      .fold(0, (sum, report) => sum + (report.values[field] as num).toInt());
  Future<int> decoded(lk.RemoteVideoTrack track) async =>
      count(await track.receiver!.getStats(), 'framesDecoded');
  Future<int> decodedAfter(lk.RemoteVideoTrack track, int before) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(seconds: 15)) {
      final frames = await decoded(track);
      if (frames > before + 5) return frames;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw StateError('SDK video did not decode after $before frames');
  }

  Future<void> observeUnkeyed(lk.RemoteVideoTrack track, String stage) async {
    final reports = await track.receiver!.getStats();
    // Keep failed negative controls visible without saving camera images.
    // ignore: avoid_print
    print(
      'SDK_NO_KEY_OBSERVATION ${jsonEncode({'pinned_provider': pinned, 'stage': stage, 'bytes_received': count(reports, 'bytesReceived'), 'frames_decoded': count(reports, 'framesDecoded'), 'frame_sizes': reports.where((report) => report.values['frameWidth'] != null).map((report) => '${report.values['frameWidth']}x${report.values['frameHeight']}').toList(), 'rendered_sizes': renderedSizes[track]!.toList(), 'observer_has_decryptor': observer.e2eeManager != null})}',
    );
    expect(observer.e2eeManager, isNull);
    expect(count(reports, 'bytesReceived'), greaterThan(0));
  }

  try {
    final initialKey = key();
    await sendingKeys.setRawKey(initialKey, participantId: 'alice');
    const url = String.fromEnvironment('GROUP_TEST_URL');
    await bob.connect(url, const String.fromEnvironment('GROUP_TEST_BOB'));
    await observer.connect(
      url,
      const String.fromEnvironment('GROUP_TEST_OBSERVER'),
    );
    await alice.connect(url, const String.fromEnvironment('GROUP_TEST_ALICE'));
    final senderPeer = alice.engine.publisher!.pc;
    if (requireEncryption) {
      expect(
        (senderPeer.getConfiguration['cryptoOptions']
            as Map)['requireFrameEncryption'],
        isTrue,
      );
    }
    final receiverPeer = bob.engine.subscriber!.pc;
    final participant = alice.localParticipant!;
    final participantSid = participant.sid;
    sampler = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (!constructorDelayed || sampling != null) return;
      sampling = () async {
        final reports = await observer.engine.subscriber!.pc.getStats();
        if (!constructorDelayed) return;
        preCryptorSamples++;
        preCryptorFrames = max(
          preCryptorFrames,
          count(reports, 'framesDecoded'),
        );
        for (final report in reports) {
          if ((report.values['framesDecoded'] as num? ?? 0) > 0) {
            preCryptorSizes.add(
              '${report.values['frameWidth']}x${report.values['frameHeight']}',
            );
          }
        }
      }().whenComplete(() => sampling = null);
    });
    final first = (await participant.setCameraEnabled(true))!;
    expect(first.encryptionType, lk.EncryptionType.kGcm);
    final firstRemote = await remote(bob, first.sid);
    final firstObserver = await remote(observer, first.sid);
    await Future<void>.delayed(const Duration(seconds: 2));
    observingInitial = false;
    sampler.cancel();
    await sampling;
    // ignore: avoid_print
    print(
      'SDK_PRE_ENCRYPTION_OBSERVATION ${jsonEncode({'require_frame_encryption': requireEncryption, 'sender_constructor_delay_ms': 1000, 'samples_before_native_constructor_forwarded': preCryptorSamples, 'max_decoded_before_native_sender_encryptor': preCryptorFrames, 'decoded_sizes_before_constructor': preCryptorSizes.toList()})}',
    );
    expect(preCryptorSamples, greaterThan(0));
    expect(preCryptorFrames, 0);
    await observeUnkeyed(firstObserver, 'initial');
    final missingKeyBaseline = await decoded(firstRemote);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(await decoded(firstRemote), missingKeyBaseline);
    expect(
      count(await first.track!.sender!.getStats(), 'framesEncoded'),
      greaterThan(5),
    );
    await receivingKeys.setRawKey(initialKey, participantId: 'alice');
    final initialFrames = await decodedAfter(firstRemote, missingKeyBaseline);

    final preparedKey = key();
    await sendingKeys.setRawKey(
      preparedKey,
      participantId: 'alice',
      keyIndex: 1,
    );
    expect(await alice.e2eeManager!.getKeyIndex('alice'), 0);
    expect(sendingKeys.getLatestIndex('alice'), pinned ? 0 : 1);
    if (sendingKeys is _PinnedKeyProvider) {
      expect(sendingKeys.preparedSlot, 1);
    }
    final preparedFrames = await decodedAfter(firstRemote, initialFrames);

    await participant.removePublishedTrack(first.sid);
    final second = (await participant.setCameraEnabled(true))!;
    expect(second.sid, isNot(first.sid));
    expect(second.encryptionType, lk.EncryptionType.kGcm);
    final secondRemote = await remote(bob, second.sid);
    final secondObserver = await remote(observer, second.sid);
    await Future<void>.delayed(const Duration(seconds: 2));
    final newCameraBaseline = await decoded(secondRemote);
    await Future<void>.delayed(const Duration(seconds: 1));
    final newIndex = await alice.e2eeManager!.getKeyIndex('alice');
    expect(newIndex, pinned ? 0 : 1);
    expect(
      count(await second.track!.sender!.getStats(), 'framesEncoded'),
      greaterThan(5),
    );
    final framesBeforeKeyDelivery = pinned
        ? await decodedAfter(secondRemote, newCameraBaseline)
        : await decoded(secondRemote);
    if (!pinned) expect(framesBeforeKeyDelivery, newCameraBaseline);
    await observeUnkeyed(secondObserver, 'republished');

    await receivingKeys.setRawKey(
      preparedKey,
      participantId: 'alice',
      keyIndex: 1,
    );
    await bob.e2eeManager!.setKeyIndex(1, participantIdentity: 'alice');
    if (sendingKeys is _PinnedKeyProvider) sendingKeys.activeSlot = 1;
    await alice.e2eeManager!.setKeyIndex(1, participantIdentity: 'alice');
    final committedFrames = await decodedAfter(
      secondRemote,
      framesBeforeKeyDelivery,
    );
    await observeUnkeyed(secondObserver, 'committed');
    expect(identical(alice.engine.publisher!.pc, senderPeer), isTrue);
    expect(identical(bob.engine.subscriber!.pc, receiverPeer), isTrue);
    expect(participant.sid, participantSid);
    return {
      'pinned_provider': pinned,
      'require_frame_encryption': requireEncryption,
      'sender_constructor_delay_ms': 1000,
      'pre_native_sender_cryptor_samples': preCryptorSamples,
      'pre_native_sender_cryptor_decoded_frames': preCryptorFrames,
      'no_media_before_native_sender_encryptor': preCryptorFrames == 0,
      'initial_missing_key_blocked': true,
      'initial_frames_after_key': initialFrames,
      'old_camera_frames_while_prepared': preparedFrames,
      'new_publication_key_index': newIndex,
      'new_camera_frames_before_future_key_delivery': framesBeforeKeyDelivery,
      'new_camera_decoded_delta_before_future_key_delivery':
          framesBeforeKeyDelivery - newCameraBaseline,
      'new_camera_frames_after_commit': committedFrames,
      'observer_decoded_counter_after_startup': await decoded(secondObserver),
      'post_startup_counter_alone_is_not_content_proof': true,
      'observer_received_rtp': true,
      'same_sfu_transport_and_participant': true,
      'publication_recreated_intentionally': true,
      'sdk_forked': false,
      'ratchet_defaults_changed': false,
      'matrix_epoch_protocol_tested': false,
      'physical_lip_sync_measured': false,
      'media_saved': false,
    };
  } finally {
    sampler?.cancel();
    await sampling;
    messenger.setMockMethodCallHandler(channel, null);
    for (final view in views) {
      view.srcObject = null;
      await view.dispose();
    }
    await alice.dispose();
    await bob.dispose();
    await observer.dispose();
    await sendingKeys.keyProvider.dispose();
    await receivingKeys.keyProvider.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final cases = switch (const String.fromEnvironment(
    'GROUP_TEST_CASE',
    defaultValue: 'both',
  )) {
    'both' => [false, true],
    'baseline' => [false],
    'pinned' => [true],
    _ => throw StateError('Unknown SDK publication case'),
  };
  for (final pinned in cases) {
    testWidgets(
      'SDK camera publication with prepared sender key (pinned=$pinned)',
      (tester) async {
        await tester.runAsync(() async {
          final proof = await probePublication(pinned: pinned);
          // ignore: avoid_print
          print('SDK_KEY_PUBLICATION_PROOF ${jsonEncode(proof)}');
        });
      },
      skip:
          !Platform.isMacOS ||
          !const bool.fromEnvironment('HARDWARE_CALL_TEST'),
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
