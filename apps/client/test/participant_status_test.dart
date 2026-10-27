import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/call_probe.dart';
import 'package:voicechat_probe/call_quality.dart';
import 'package:voicechat_probe/direct_call.dart';
import 'package:voicechat_probe/participant_quality.dart';
import 'chat_actions_test.dart' show VideoSession, OutboxRoom;
import 'conversation_list_test.dart' show ListClient;

class Microphone extends Fake
    implements lk.RemoteTrackPublication<lk.RemoteAudioTrack> {
  @override
  bool muted = false;
  @override
  lk.TrackSource get source => lk.TrackSource.microphone;
}

class Peer extends Fake implements lk.RemoteParticipant {
  @override
  final String identity;
  Peer(this.identity);
  @override
  lk.ConnectionQuality connectionQuality = lk.ConnectionQuality.unknown;
  @override
  final audioTrackPublications =
      <lk.RemoteTrackPublication<lk.RemoteAudioTrack>>[];
}

class Media extends Fake implements lk.Room {
  final peers = <String, lk.RemoteParticipant>{};
  @override
  UnmodifiableMapView<String, lk.RemoteParticipant> get remoteParticipants =>
      UnmodifiableMapView(peers);
}

class Group extends Fake implements CallProbe {
  @override
  final mx.Room chat;
  Group(this.chat);
  @override
  final Media media = Media();
  @override
  String get identity => '${chat.client.userID}/phone';
  @override
  bool muted = false;
}

class RemoteFeed extends Fake implements mx.WrappedMediaStream {
  @override
  bool audioMuted = false;
}

class DirectSession extends VideoSession {
  @override
  final mx.Room room;
  DirectSession(this.room);
  @override
  final RemoteFeed remoteUserMediaStream = RemoteFeed();
}

void main() {
  testWidgets('Group status follows each peer; absent metadata stays unknown', (
    tester,
  ) async {
    final call = Group(OutboxRoom(ListClient()));
    final alice = Peer('@alice:local/phone')
      ..connectionQuality = lk.ConnectionQuality.excellent;
    final bob = Peer('@bob:local/laptop')
      ..connectionQuality = lk.ConnectionQuality.poor;
    final mic = Microphone();
    alice.audioTrackPublications.add(mic);
    call.media.peers.addAll({'alice': alice, 'bob': bob});
    expect(participantQuality(call, '@alice:local'), CallQuality.excellent);
    expect(participantQuality(call, bob.identity), CallQuality.poor);
    expect(participantQuality(call, '@missing:local'), CallQuality.unknown);
    expect(participantMicrophoneMuted(call, '@missing:local'), isNull);
    expect(participantMicrophoneMuted(call, '@alice:local'), false);
    expect(participantMicrophoneMuted(call, '@bob:local'), true);
    Future<void> render() => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ParticipantStatusBadge(call: call, identity: '@alice:local'),
        ),
      ),
    );
    await render();
    expect(find.byTooltip('Микрофон включён'), findsOneWidget);
    mic.muted = true;
    await render();
    expect(find.byTooltip('Микрофон выключен'), findsOneWidget);
    expect(participantQuality(call, '@alice:local'), CallQuality.excellent);
    call.muted = true;
    expect(participantMicrophoneMuted(call, call.identity), true);
    mic.muted = false;
    expect(participantMicrophoneMuted(call, '@alice:local'), false);
  });
  test(
    'Personal call reads remote mute without confusing it with local mute',
    () async {
      final session = DirectSession(OutboxRoom(ListClient()));
      final call = DirectCall(session, () {}, (_) {});
      expect(participantMicrophoneMuted(call, '@peer:local'), false);
      session.remoteUserMediaStream.audioMuted = true;
      expect(participantMicrophoneMuted(call, '@peer:local'), true);
      await call.close();
    },
  );
}
