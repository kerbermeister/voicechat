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
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

class SoundCalls extends Fake implements CallController {
  @override
  VoiceCall? active;
  @override
  bool get starting => false;
  @override
  List<DirectCall> get directInvitations => [];
  @override
  Map<String, CallInvitation> get invitations => {};
}

void main() {
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
