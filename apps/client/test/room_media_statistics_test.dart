// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:livekit_client/src/core/engine.dart';
import 'package:livekit_client/src/core/transport.dart';
import 'package:voicechat_probe/routed_livekit_engine.dart';

class Peer extends Fake implements rtc.RTCPeerConnection {
  int reads = 0;
  final double rtt;
  Peer({this.rtt = .02});
  Completer<List<rtc.StatsReport>>? pending;
  @override
  Future<List<rtc.StatsReport>> getStats([rtc.MediaStreamTrack? track]) async {
    reads++;
    if (pending != null) return pending!.future;
    return [
      rtc.StatsReport('private-track', 'inbound-rtp', reads * 1000.0, {
        'kind': 'audio',
        'bytesReceived': reads * 1000,
        'ip': 'private-address',
        'transportId': 'private-transport',
      }),
      rtc.StatsReport('private-transport', 'transport', reads * 1000.0, {
        'selectedCandidatePairId': 'private-pair',
      }),
      rtc.StatsReport('private-pair', 'candidate-pair', reads * 1000.0, {
        'state': 'succeeded',
        'currentRoundTripTime': rtt,
      }),
    ];
  }
}

class StatsTransport extends Fake implements Transport {
  @override
  final Peer pc;
  StatsTransport(this.pc);
}

class StatsEngine extends Fake implements Engine {
  @override
  Transport? publisher;
  @override
  Transport? subscriber;
}

class StatsRoom extends Fake implements lk.Room {
  @override
  final StatsEngine engine = StatsEngine();
}

void main() {
  testWidgets('A stopped room cannot continue periodic sampling', (
    tester,
  ) async {
    final room = StatsRoom(), peer = Peer();
    room.engine.publisher = StatsTransport(peer);
    final sampler = RoomMediaStatistics()..start(room);
    await tester.pump(const Duration(seconds: 3));
    expect(peer.reads, 1);
    sampler.stop();
    await tester.pump(const Duration(seconds: 30));
    expect(peer.reads, 1);
  });
  test(
    'A room samples each transport once, keeps separate indices and bounds history',
    () async {
      final room = StatsRoom();
      final first = Peer(), second = Peer(rtt: .1);
      room.engine
        ..publisher = StatsTransport(first)
        ..subscriber = StatsTransport(second);
      final sampler = RoomMediaStatistics()..start(room);
      try {
        for (var i = 0; i < 65; i++) {
          await sampler.sample();
        }
        expect(first.reads, 65);
        expect(second.reads, 65);
        expect(sampler.history.length, 60);
        final streams = sampler.history.last['streams'] as List;
        expect(streams.length, 2);
        expect(streams.map((x) => x['stream_index']).toSet().length, 2);
        expect(streams.every((x) => x['bitrate_bps'] == 8000), true);
        expect(streams.map((x) => x['rtt_ms']).toSet(), {20.0, 100.0});
        expect(jsonEncode(sampler.history), isNot(contains('private')));
      } finally {
        sampler.stop();
      }
      await sampler.sample();
      expect(first.reads, 65);
    },
  );
  for (final replace in [false, true]) {
    test(
      'Late transport snapshots are discarded after ${replace ? 'replacement' : 'stop'}',
      () async {
        final room = StatsRoom(), peer = Peer();
        peer.pending = Completer<List<rtc.StatsReport>>();
        room.engine.publisher = StatsTransport(peer);
        final sampler = RoomMediaStatistics()..start(room);
        final pending = sampler.sample();
        if (replace) {
          room.engine.publisher = StatsTransport(Peer());
        } else {
          sampler.stop();
        }
        peer.pending!.complete([
          rtc.StatsReport('old-track', 'inbound-rtp', 1000, {
            'kind': 'audio',
            'bytesReceived': 999,
          }),
        ]);
        await pending;
        if (replace) {
          expect(sampler.history.single['streams'], isEmpty);
        } else {
          expect(sampler.history, isEmpty);
        }
        sampler.stop();
      },
    );
  }
  test(
    'Failed statistics are diagnostic gaps, never raw error payloads',
    () async {
      final room = StatsRoom(), peer = Peer();
      peer.pending = Completer<List<rtc.StatsReport>>();
      room.engine.publisher = StatsTransport(peer);
      final sampler = RoomMediaStatistics()..start(room);
      final pending = sampler.sample();
      peer.pending!.completeError(StateError('private-origin-and-token'));
      await pending;
      expect(sampler.history.single['statistics'], 'unavailable');
      expect(jsonEncode(sampler.history), isNot(contains('private')));
      sampler.stop();
    },
  );
}
