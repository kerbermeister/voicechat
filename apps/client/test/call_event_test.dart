import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/call_event.dart';
import 'package:voicechat_probe/call_window.dart';
import 'package:voicechat_probe/theme.dart';
import 'package:voicechat_probe/direct_call.dart';
import 'message_test.dart' show TestClient;
import 'chat_actions_test.dart' show OutboxDatabase, VideoSession;

class TimedSession extends VideoSession {
  CallState current = CallState.kInviteSent;
  @override
  CallState get state => current;
}

void main() {
  final room = Room(
    id: '!call:local',
    client: Client('call-event-test', database: OutboxDatabase()),
  );
  Event invite(Object? offer) => Event.fromJson({
    'type': EventTypes.CallInvite,
    'event_id': r'$invite',
    'sender': '@caller:local',
    'content': {'offer': offer},
  }, room);
  test(
    'Call direction follows initiator, not the participant who ended or declined',
    () {
      final client = TestClient();
      final room = Room(id: '!direction:local', client: client);
      Event event(
        String sender,
        Map<String, dynamic> content, {
        String type = EventTypes.Message,
      }) => Event.fromJson({
        'type': type,
        'event_id': r'$e',
        'sender': sender,
        'content': content,
      }, room);
      final outgoing = event(client.userID, {
        'call_id': 's',
        'offer': {'sdp': 'm=audio '},
      }, type: EventTypes.CallInvite);
      expect(callDirectionLabel(outgoing), 'Исходящий звонок');
      final incoming = event('@peer:local', {
        'msgtype': 'dev.voicechat.call',
        'action': 'invite',
        'session': 's',
      });
      expect(callDirectionLabel(incoming), 'Входящий звонок');
      final end = event(client.userID, {
        'msgtype': 'dev.voicechat.call',
        'action': 'end',
        'session': 's',
      });
      expect(callDirectionLabel(end, history: [incoming]), 'Входящий звонок');
      end.content['dev.voicechat.call_initiator'] = '@peer:local';
      expect(callDirectionLabel(end), 'Входящий звонок');
      final declined = event('@peer:local', {
        'msgtype': 'dev.voicechat.call',
        'action': 'decline',
        'session': 's',
      });
      expect(
        callDirectionLabel(declined, history: [outgoing]),
        'Исходящий звонок',
      );
      expect(
        callDirectionLabel(declined),
        isNull,
        reason:
            'Do not invent a direction for legacy events with missing history',
      );
      final summary = event(client.userID, {
        'msgtype': 'dev.voicechat.call_summary',
      });
      expect(callDirectionLabel(summary), 'Исходящий звонок');
      summary.content['dev.voicechat.forwarded_author'] = 'original';
      expect(callDirectionLabel(summary), isNull);
    },
  );
  test(
    'Native Matrix invitations distinguish video without displaying SDP',
    () {
      expect(
        callEventLabel(invite({'sdp': 'v=0\r\nm=audio 9 RTP/SAVPF 111\r\n'})),
        'Голосовой звонок',
      );
      expect(
        callEventLabel(invite({'sdp': 'v=0\r\nm=video 9 RTP/SAVPF 96\r\n'})),
        'Видеозвонок',
      );
      expect(callEventLabel(invite({'sdp': {}})), 'Голосовой звонок');
      expect(callEventLabel(invite(null)), 'Голосовой звонок');
    },
  );
  testWidgets(
    'Call cards distinguish video and legacy audio; only valid connected duration is shown',
    (tester) async {
      final ended = Event.fromJson({
        'type': EventTypes.Message,
        'event_id': r'$end',
        'sender': '@caller:local',
        'content': <String, dynamic>{
          'msgtype': 'dev.voicechat.call_summary',
          'body': 'Видеозвонок завершён',
          'video': true,
          'duration_ms': 65000,
        },
      }, room);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> show(Event event, AppPalette palette) => tester.pumpWidget(
        MaterialApp(
          theme: palette.theme,
          home: Scaffold(body: CallEventCard(event: event)),
        ),
      );
      for (final palette in AppPalette.values) {
        ended.content['duration_ms'] = 65000;
        await show(ended, palette);
        expect(find.text('Видеозвонок завершён · 1:05'), findsOneWidget);
        expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
        expect(tester.takeException(), isNull);
        for (final duration in [null, 0, -1, '65000', 86400001]) {
          ended.content['duration_ms'] = duration;
          await show(ended, palette);
          expect(find.text('Видеозвонок завершён'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        await show(invite({'sdp': 'm=audio 9 RTP/SAVPF 111\r\n'}), palette);
        expect(find.text('Голосовой звонок'), findsOneWidget);
        expect(find.byIcon(Icons.call_outlined), findsOneWidget);
        await show(invite({'sdp': 'm=video 9 RTP/SAVPF 96\r\n'}), palette);
        expect(find.text('Видеозвонок'), findsOneWidget);
        expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
      }
    },
  );
  test('Direct call duration excludes dialling and stops at hangup', () async {
    final session = TimedSession();
    final call = DirectCall(session, () {}, (_) {});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(call.duration, Duration.zero);
    session.current = CallState.kConnected;
    session.onCallStateChanged.add(CallState.kConnected);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(call.duration, greaterThan(Duration.zero));
    await call.close();
    final elapsed = call.duration;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(call.duration, elapsed);
  });
}
