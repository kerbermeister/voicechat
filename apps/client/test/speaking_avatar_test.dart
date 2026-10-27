import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:voicechat_probe/audio_levels.dart';
import 'package:voicechat_probe/speaking_avatar.dart';
import 'participant_status_test.dart' show Group, Peer, Microphone;
import 'chat_actions_test.dart' show OutboxRoom;
import 'conversation_list_test.dart' show ListClient;

class SpeakingGroup extends Group {
  SpeakingGroup(super.chat);
  @override
  bool isClosed = false;
}

class SpeakingPeer extends Peer {
  SpeakingPeer(super.identity);
  double _level = 0;
  @override
  double get audioLevel => _level;
  @override
  set audioLevel(double value) => _level = value;
  @override
  bool isSpeaking = false;
}

void main() {
  StatsReport report(String id, String type, Map<String, dynamic> values) =>
      StatsReport(id, type, 0, {'kind': 'audio', ...values});
  test(
    'WebRTC levels distinguish sender/receiver, use energy deltas and never invent missing speech',
    () {
      final levels = AudioLevels();
      levels.read([
        report('local', 'media-source', {'audioLevel': .1}),
        report('remote', 'inbound-rtp', {'audioLevel': '0.4'}),
        report('other', 'remote-inbound-rtp', {'audioLevel': 1}),
      ]);
      expect(levels.local, .1);
      expect(levels.remote, .4);
      StatsReport energy(double energy, double duration) => report(
        'remote',
        'inbound-rtp',
        {'totalAudioEnergy': energy, 'totalSamplesDuration': duration},
      );
      levels.read([energy(1, 10)]);
      expect(levels.remote, 0);
      levels.read([energy(1.04, 11)]);
      expect(levels.remote, closeTo(.2, .00001));
      levels.read([energy(1.04, 12)]);
      expect(levels.remote, 0);
      levels.read([energy(.01, 1)]);
      expect(levels.remote, 0);
      levels.read([
        report('bad', 'inbound-rtp', {'audioLevel': double.nan}),
        report('video', 'inbound-rtp', {'kind': 'video', 'audioLevel': 1}),
      ]);
      expect(levels.remote, 0);
      levels.read([]);
      expect(levels.local, 0);
    },
  );
  testWidgets(
    'Avatar follows only its speaker and becomes still on mute, silence and screen display',
    (tester) async {
      final call = SpeakingGroup(OutboxRoom(ListClient()));
      final alice = SpeakingPeer('@alice:local/phone');
      final bob = SpeakingPeer('@bob:local/phone')
        ..isSpeaking = true
        ..audioLevel = .8;
      final mic = Microphone();
      alice.audioTrackPublications.add(mic);
      bob.audioTrackPublications.add(Microphone());
      call.media.peers.addAll({'a': alice, 'b': bob});
      bool enabled = true, reduced = false;
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Center(
              child: SpeakingAvatar(
                call: call,
                identity: '@alice:local',
                enabled: enabled,
                child: const SizedBox(width: 64, height: 64),
              ),
            ),
          ),
        ),
      );
      await show();
      final size = tester.getSize(find.byType(SpeakingAvatar));
      await tester.pump(const Duration(milliseconds: 160));
      expect(tester.widget<SpeechRing>(find.byType(SpeechRing)).level, 0);
      alice
        ..isSpeaking = true
        ..audioLevel = .16;
      await tester.pump(const Duration(milliseconds: 160));
      expect(tester.widget<SpeechRing>(find.byType(SpeechRing)).level, 1);
      alice.audioLevel = .01;
      await tester.pump(const Duration(milliseconds: 160));
      expect(
        tester.widget<SpeechRing>(find.byType(SpeechRing)).level,
        closeTo(.25, .001),
      );
      mic.muted = true;
      await tester.pump(const Duration(milliseconds: 160));
      expect(tester.widget<SpeechRing>(find.byType(SpeechRing)).level, 0);
      mic.muted = false;
      alice.isSpeaking = false;
      expect(participantSpeechLevel(call, alice.identity), 0);
      alice.isSpeaking = true;
      reduced = true;
      await show();
      await tester.pump(const Duration(milliseconds: 160));
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      enabled = false;
      await show();
      await tester.pump(const Duration(milliseconds: 160));
      expect(tester.widget<SpeechRing>(find.byType(SpeechRing)).level, 0);
      expect(tester.getSize(find.byType(SpeakingAvatar)), size);
      call.isClosed = true;
      expect(participantSpeechLevel(call, alice.identity), 0);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
