import 'dart:async';
import 'route_fixture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/voip/models/call_options.dart';
import 'package:voicechat_probe/media_routes.dart';
import 'package:voicechat_probe/route_config.dart';
import 'chat_actions_test.dart' show OutboxDatabase;

class RestartPeer implements RTCPeerConnection {
  final steps = <String>[];
  Map<String, dynamic> configuration = {
    'sdpSemantics': 'unified-plan',
    'iceServers': [],
  };
  @override
  Map<String, dynamic> get getConfiguration => configuration;
  @override
  Future<void> setConfiguration(Map<String, dynamic> value) async {
    configuration = value;
    steps.add('configure');
  }

  @override
  Future<void> restartIce() async {
    steps.add('restart');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RestartVoip implements VoIP {
  final Completer<List<Map<String, dynamic>>> servers;
  RestartVoip(this.servers);
  @override
  Future<List<Map<String, dynamic>>> getIceServers() => servers.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('TURN settings are temporary and confined to the signed host set', () {
    final config = RouteConfig.parse(routeFixture('three-vps.example.json'));
    TurnServerCredentials credentials(List<String> urls, {int ttl = 3600}) =>
        TurnServerCredentials(
          password: 'temporary',
          username: 'temporary-user',
          ttl: ttl,
          uris: urls.map(Uri.parse).toList(),
        );
    final accepted = verifiedTurnServers(
      credentials([
        'turn:turn-b.example.com:3478?transport=udp',
        'turns:turn-c.example.com:443?transport=tcp',
      ]),
      config,
    );
    expect(accepted.single['urls'], hasLength(2));
    final duringCatalogUpdate = verifiedTurnServers(
      credentials([
        'turn:turn-b.example.com:3478?transport=udp',
        'turn:turn-d.example.com:3478?transport=udp',
      ]),
      config,
    );
    expect(duringCatalogUpdate.single['urls'], [
      'turn:turn-b.example.com:3478?transport=udp',
    ]);
    for (final value in [
      credentials(['turn:other.example.com:3478']),
      credentials(['turn:user@turn-b.example.com:3478']),
      credentials(['turn:turn-b.example.com:3478/path']),
      credentials(['turns:turn-b.example.com:443?transport=udp']),
      credentials(['turn:turn-b.example.com:3478?other=1']),
      credentials(['turn://turn-b.example.com:3478']),
      credentials(['turn:turn-b.example.com:0']),
      credentials(['turn:turn-b.example.com:3478'], ttl: 0),
      credentials([]),
    ]) {
      expect(() => verifiedTurnServers(value, config), throwsFormatException);
    }
  });

  test(
    'ICE restart refreshes credentials first and ignores a replaced peer',
    () async {
      final client = Client('restart', database: OutboxDatabase());
      addTearDown(client.dispose);
      final room = Room(client: client, id: '!room:test');
      for (final replaced in [false, true]) {
        final credentials = Completer<List<Map<String, dynamic>>>();
        final call = CallSession(
          CallOptions(
            callId: 'call',
            type: CallType.kVoice,
            dir: CallDirection.kOutgoing,
            localPartyId: 'device',
            voip: RestartVoip(credentials),
            room: room,
            iceServers: [],
          ),
        );
        final peer = RestartPeer();
        call.pc = peer;
        final pending = call.restartIce();
        expect(peer.steps, isEmpty);
        if (replaced) call.pc = RestartPeer();
        final servers = [
          {
            'urls': ['turn:new.test:3478'],
            'username': 'fresh',
            'credential': 'fresh',
          },
        ];
        credentials.complete(servers);
        await pending;
        expect(peer.steps, replaced ? [] : ['configure', 'restart']);
        if (!replaced) {
          expect(peer.configuration['iceServers'], servers);
          expect(peer.configuration['sdpSemantics'], 'unified-plan');
        }
      }
    },
  );
}
