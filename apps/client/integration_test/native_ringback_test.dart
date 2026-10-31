// Real platform audio backend; no account, network, microphone or phone calls.
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'audio_playback_fixture.dart';
import 'package:voicechat_probe/app_sounds.dart';
import 'package:voicechat_probe/call_controller.dart';
import 'package:voicechat_probe/direct_call.dart';
import 'package:voicechat_probe/voice_call.dart';

class DialState extends Fake implements CallController {
  @override
  bool starting = false;
  @override
  VoiceCall? get active => null;
  @override
  List<DirectCall> get directInvitations => [];
  @override
  Map<String, CallInvitation> get invitations => {};
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Native ringback stops on repeated cancellation and disposal',
    (tester) async {
      final client = AudioFixtureClient();
      final player = AudioPlayer();
      final sounds = AppSounds(client, ringing: player);
      final calls = DialState();
      try {
        await player.setReleaseMode(ReleaseMode.loop);
        for (var i = 0; i < 3; i++) {
          final playing = player.onPlayerStateChanged.firstWhere(
            (state) => state == PlayerState.playing,
          );
          calls.starting = true;
          sounds.updateCall(calls);
          await playing.timeout(const Duration(seconds: 8));
          final stopped = player.onPlayerStateChanged.firstWhere(
            (state) => state == PlayerState.stopped,
          );
          calls.starting = false;
          sounds.updateCall(calls);
          await stopped.timeout(const Duration(seconds: 2));
          await Future<void>.delayed(const Duration(milliseconds: 400));
          expect(player.state, PlayerState.stopped);
        }
      } finally {
        await sounds.close();
        }
    },
    skip:
        !Platform.isMacOS || !const bool.fromEnvironment('HARDWARE_AUDIO_TEST'),
  );
}
