import 'dart:async';
import 'package:flutter/services.dart';
import 'package:voicechat_probe/call_devices.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/app_sounds.dart';
import 'package:voicechat_probe/call_controller.dart';
import 'package:voicechat_probe/direct_call.dart';
import 'package:voicechat_probe/voice_call.dart';
import 'call_window_test.dart' show WindowCall, CallRoom, WindowDatabase;

class SoundPlayer extends Fake implements AudioPlayer {
  final played = <String>[];
  int stops = 0;
  Completer<void>? pendingPlay;
  @override
  Future<void> play(
    Source source, {
    double? volume,
    double? balance,
    AudioContext? ctx,
    Duration? position,
    PlayerMode? mode,
  }) async {
    played.add((source as AssetSource).path);
    await pendingPlay?.future;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {}
}

class SoundCalls extends Fake implements CallController {
  @override
  VoiceCall? active;
  @override
  bool starting = false;
  @override
  late CallDevices devices;
  @override
  List<DirectCall> get directInvitations => [];
  @override
  Map<String, CallInvitation> get invitations => {};
}

class WaitingCall extends WindowCall {
  WaitingCall(super.chat);
  final cleanup = Completer<void>();
  @override
  Duration get duration => Duration.zero;
  @override
  Future<void> close() async {
    isClosed = true;
    await cleanup.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Cancel stops a preparing ring immediately; late playback cannot restore it',
    () async {
      final client = Client('late-ring', database: WindowDatabase());
      final player = SoundPlayer()..pendingPlay = Completer<void>();
      final sounds = AppSounds(client, effect: SoundPlayer(), ringing: player);
      final calls = SoundCalls()..starting = true;
      sounds.updateCall(calls);
      await Future<void>.delayed(Duration.zero);
      expect(player.played, ['sounds/ringback.wav']);
      final stops = player.stops;
      calls.starting = false;
      sounds.updateCall(calls);
      await Future<void>.delayed(Duration.zero);
      expect(player.stops, greaterThan(stops));
      player.pendingPlay!.complete();
      await Future<void>.delayed(Duration.zero);
      final stopped = player.stops;
      player.pendingPlay = null;
      calls.starting = true;
      sounds.updateCall(calls);
      await Future<void>.delayed(Duration.zero);
      calls.starting = false;
      sounds.updateCall(calls);
      await Future<void>.delayed(Duration.zero);
      expect(player.played.length, 2);
      expect(player.stops, greaterThan(stopped));
      await sounds.close();
      await client.dispose();
    },
  );
  test(
    'Hangup stops ringback before slow cleanup, including cancel during dial startup',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Event'),
        (_) async => null,
      );
      final client = Client('cancel-dial', database: WindowDatabase());
      final player = SoundPlayer();
      final sounds = AppSounds(client, effect: SoundPlayer(), ringing: player);
      final calls = CallController(
        client,
        'http://localhost',
        'ws://localhost',
        (_) {},
      );
      calls.addListener(() => sounds.updateCall(calls));
      for (final hasCall in [false, true]) {
        final call = hasCall ? WaitingCall(CallRoom(client)) : null;
        calls.active = call;
        calls.starting = true;
        calls.dialingRoom = CallRoom(client);
        sounds.updateCall(calls);
        await Future<void>.delayed(Duration.zero);
        final stops = player.stops;
        final ending = calls.end();
        await Future<void>.delayed(Duration.zero);
        expect(calls.starting, false);
        expect(player.stops, greaterThan(stops));
        call?.cleanup.complete();
        await ending;
      }
      await calls.close();
      await sounds.close();
      await client.dispose();
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Event'),
        null,
      );
    },
  );
  test('Deletion effect respects disabled sounds and closed player', () async {
    final client = Client('delete-sounds', database: WindowDatabase());
    final effect = SoundPlayer();
    final sounds = AppSounds(client, effect: effect, ringing: SoundPlayer());
    sounds.deleted();
    await Future<void>.delayed(Duration.zero);
    expect(effect.played, ['sounds/deleted.wav']);
    sounds.enabled = false;
    sounds.deleted();
    await Future<void>.delayed(Duration.zero);
    expect(effect.played.length, 1);
    sounds.enabled = true;
    await sounds.close();
    sounds.deleted();
    await Future<void>.delayed(Duration.zero);
    expect(effect.played.length, 1);
    await client.dispose();
  });
  test(
    'End tone plays once for local or remote close and obeys sound settings',
    () async {
      final client = Client('sounds', database: WindowDatabase());
      final effect = SoundPlayer(), ringing = SoundPlayer();
      final sounds = AppSounds(client, effect: effect, ringing: ringing);
      final calls = SoundCalls()..active = WindowCall(CallRoom(client));
      sounds.updateCall(calls);
      await calls.active!.close();
      sounds.updateCall(calls);
      sounds.updateCall(calls);
      await Future<void>.delayed(Duration.zero);
      expect(effect.played, ['sounds/ended.wav']);
      sounds.enabled = false;
      calls.active = WindowCall(CallRoom(client));
      sounds.updateCall(calls);
      await calls.active!.close();
      sounds.updateCall(calls);
      sounds.enabled = true;
      sounds.updateCall(calls);
      await Future<void>.delayed(Duration.zero);
      expect(effect.played.length, 1);
      await sounds.close();
      await client.dispose();
    },
  );
}
