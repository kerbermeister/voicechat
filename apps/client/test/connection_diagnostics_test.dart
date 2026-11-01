import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/connection_diagnostics.dart';
import 'package:voicechat_probe/direct_call.dart';
import 'chat_actions_test.dart' show VideoSession, OutboxRoom;
import 'conversation_list_test.dart' show ListClient;
import 'call_window_test.dart' show WindowCall, CallRoom, WindowDatabase;

class StatisticsPeer extends Fake implements rtc.RTCPeerConnection {
  @override
  Future<List<rtc.StatsReport>> getStats([
    rtc.MediaStreamTrack? track,
  ]) async => [
    rtc.StatsReport('private-track-id', 'inbound-rtp', 0, {
      'kind': 'video',
      'codecId': 'private-codec-id',
      'packetsReceived': 400,
      'framesDecoded': 1,
      'trackIdentifier': 'private-camera-id',
      'ip': 'private-address',
    }),
    rtc.StatsReport('private-codec-id', 'codec', 0, {'mimeType': 'video/H264'}),
  ];
}

class StatisticsSession extends VideoSession {
  @override
  final Room room;
  StatisticsSession(this.room);
  @override
  final pc = StatisticsPeer();
}

void main() {
  test(
    'Receiver diagnostics distinguish packets from decoded frames without identifiers',
    () async {
      final call = DirectCall(
        StatisticsSession(OutboxRoom(ListClient())),
        () {},
        (_) {},
      );
      expect(await call.receivedVideoStatistics(), [
        {'packetsReceived': 400, 'framesDecoded': 1, 'codec': 'video/H264'},
      ]);
      await call.close();
    },
  );
  test(
    'Diagnostic report omits peer, room, session and server identities',
    () async {
      final client = Client(
        'private-account-fixture',
        database: WindowDatabase(),
      );
      final call = WindowCall(CallRoom(client), video: false);
      final snapshot = await connectionDiagnostics(null, call);
      expect(snapshot['schema'], 1);
      expect((snapshot['call'] as Map)['duration_ms'], 42000);
      final text = jsonEncode(snapshot);
      for (final secret in [
        'private-account-fixture',
        call.chat.id,
        call.session,
        'access_token',
        'password',
      ]) {
        expect(text, isNot(contains(secret)));
      }
      call.isClosed = true;
      expect((await connectionDiagnostics(null, call))['call'], {
        'state': 'inactive',
      });
      expect((await connectionDiagnostics(null, null))['call'], {
        'state': 'inactive',
      });
      await client.dispose();
    },
  );
}
