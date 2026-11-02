// Real native RPCs, except one injected encryption failure or delayed reply.
// No accounts, media files or playback. Only the isolated local SFU is used.
// ignore_for_file: invalid_use_of_internal_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

Future<Map<String, Object>> probeFailure(String failure, bool audio) async {
  final keys = await lk.BaseKeyProvider.create(sharedKey: false);
  await keys.setRawKey(Uint8List(32), participantId: 'alice');
  final room = lk.Room(
    roomOptions: lk.RoomOptions(encryption: lk.E2EEOptions(keyProvider: keys)),
  );
  const channel = MethodChannel('FlutterWebRTC.Method');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final reached = Completer<void>(), release = Completer<void>();
  final created = <String>{}, disposed = <String, int>{}, stopped = <String>{};
  var injected = false;
  messenger.setMockMethodCallHandler(channel, (call) async {
    final arguments = call.arguments as Map? ?? {};
    if (failure == 'index_false' &&
        call.method == 'frameCryptorSetKeyIndex' &&
        created.contains(arguments['frameCryptorId'])) {
      injected = true;
      return {'result': false};
    }
    if (failure == 'activate_false' &&
        call.method == 'rtpSenderSetParameters' &&
        created.isNotEmpty) {
      injected = true;
      return {'result': false};
    }
    final constructor =
        call.method == 'frameCryptorFactoryCreateFrameCryptor' &&
        arguments['type'] == 'sender';
    if (constructor && failure == 'constructor') {
      injected = true;
      throw PlatformException(
        code: 'probe_constructor',
        message: 'Synthetic constructor failure',
      );
    }
    if (call.method == 'frameCryptorSetEnabled' &&
        arguments['enabled'] == true &&
        created.contains(arguments['frameCryptorId'])) {
      if (failure == 'enable_exception') {
        injected = true;
        throw PlatformException(
          code: 'probe_enable',
          message: 'Synthetic enable failure',
        );
      }
      if (failure == 'enable_false') {
        injected = true;
        return {'result': false};
      }
    }
    final bytes = await messenger.delegate.send(
      channel.name,
      channel.codec.encodeMethodCall(call),
    );
    if (bytes == null) {
      throw MissingPluginException('Native WebRTC unavailable');
    }
    final reply = channel.codec.decodeEnvelope(bytes);
    if (constructor) {
      created.add((reply as Map)['frameCryptorId'] as String);
      if (failure == 'close_pending') {
        injected = true;
        reached.complete();
        // The native cryptor exists, but its real reply has not reached the SDK.
        await release.future;
      }
    }
    if (call.method == 'frameCryptorDispose') {
      final id = arguments['frameCryptorId'] as String;
      disposed.update(id, (count) => count + 1, ifAbsent: () => 1);
    }
    if (call.method == 'trackDispose') {
      stopped.add(arguments['trackId'] as String);
    }
    return reply;
  });
  lk.LocalTrack? track;
  Object? publicationError;
  var closeWaited = false;
  try {
    await room.connect(
      const String.fromEnvironment('GROUP_TEST_URL'),
      const String.fromEnvironment('GROUP_TEST_ALICE'),
    );
    final participant = room.localParticipant!;
    track = audio
        ? await lk.LocalAudioTrack.create()
        : await lk.LocalVideoTrack.createCameraTrack();
    final trackId = track.mediaStreamTrack.id;
    final pending = () async {
      try {
        if (track is lk.LocalAudioTrack) {
          await participant.publishAudioTrack(track);
        } else {
          await participant.publishVideoTrack(track as lk.LocalVideoTrack);
        }
      } catch (error) {
        publicationError = error;
      }
    }();
    if (failure == 'close_pending') {
      await reached.future.timeout(const Duration(seconds: 10));
      var closed = false;
      final closing = room.dispose().then((_) => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      closeWaited = !closed;
      release.complete();
      await closing.timeout(const Duration(seconds: 10));
    }
    await pending.timeout(const Duration(seconds: 15));
    expect(injected, isTrue);
    expect(publicationError, isNotNull);
    expect(participant.trackPublications, isEmpty);
    expect(stopped, contains(trackId));
    expect(track.isActive, isFalse);
    if (failure == 'close_pending') expect(closeWaited, isTrue);
    if (!room.isDisposed) await room.dispose();
    expect(disposed.keys.toSet(), created);
    expect(disposed.values, everyElement(1));
    return {
      'failure': failure,
      'media': audio ? 'audio' : 'video',
      'publication_rejected': true,
      'capture_stopped': true,
      'created_sender_cryptors': created.length,
      'cryptors_disposed_once': true,
      'close_awaited_pending_native_reply': closeWaited,
      'media_saved': false,
    };
  } finally {
    if (!release.isCompleted) release.complete();
    if (!room.isDisposed) await room.dispose();
    await track?.dispose();
    await keys.keyProvider.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final audio in [false, true]) {
    for (final failure in [
      'constructor',
      'enable_exception',
      'enable_false',
      'index_false',
      'activate_false',
      'close_pending',
    ]) {
      testWidgets(
        'Encrypted ${audio ? 'audio' : 'video'} rejects $failure',
        (tester) async {
          await tester.runAsync(() async {
            final proof = await probeFailure(failure, audio);
            // ignore: avoid_print
            print('SDK_KEY_FAILURE_PROOF ${jsonEncode(proof)}');
          });
        },
        skip:
            !(Platform.isMacOS || Platform.isAndroid) ||
            !const bool.fromEnvironment('HARDWARE_CALL_TEST'),
        timeout: const Timeout(Duration(minutes: 1)),
      );
    }
  }
}
