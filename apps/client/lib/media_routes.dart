import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart' as mx;
import 'route_config.dart';
import 'route_transport.dart';
import 'routed_livekit_engine.dart';
export 'routed_livekit_engine.dart' show mediaNetworkFailure;

List<Map<String, dynamic>> verifiedTurnServers(
  mx.TurnServerCredentials credentials,
  RouteConfig config,
) {
  final allowed = config.edges.map((e) => e.turnHost).toSet();
  if (credentials.ttl < 1 ||
      credentials.ttl > 86400 ||
      credentials.username.isEmpty ||
      credentials.username.length > 512 ||
      credentials.password.isEmpty ||
      credentials.password.length > 512 ||
      credentials.uris.isEmpty ||
      credentials.uris.length > 128) {
    throw const FormatException('Invalid temporary TURN credentials');
  }
  final urls = <String>[];
  for (final uri in credentials.uris) {
    if (!{'turn', 'turns'}.contains(uri.scheme) ||
        uri.hasAuthority ||
        uri.hasFragment ||
        RegExp(r'\s').hasMatch(uri.toString()) ||
        !{'transport=tcp', 'transport=udp', ''}.contains(uri.query) ||
        (uri.scheme == 'turns' && uri.query == 'transport=udp')) {
      throw const FormatException('Invalid TURN URI');
    }
    final address = Uri.parse('https://${uri.path}');
    if (address.userInfo.isNotEmpty ||
        address.path.isNotEmpty ||
        address.host.isEmpty ||
        address.port < 1 ||
        address.port > 65535) {
      throw const FormatException('Invalid TURN address');
    }
    // Core and cached catalogs update at different times. Keep using the
    // intersection; never send credentials to a host not yet signed for us.
    if (allowed.contains(address.host)) urls.add(uri.toString());
  }
  if (urls.isEmpty) {
    throw const FormatException('No TURN server in the trusted catalog');
  }
  return [
    {
      'urls': urls,
      'username': credentials.username,
      'credential': credentials.password,
    },
  ];
}

class RoutedVoIP extends mx.VoIP {
  RoutedVoIP(super.client, super.delegate);

  @override
  Future<List<Map<String, dynamic>>> getIceServers() async {
    final network = routeTransportOf(client.httpClient);
    if (network == null || network.coordinator == null) {
      return super.getIceServers();
    }
    return mediaIceServers(client);
  }
}

Future<List<Map<String, dynamic>>> mediaIceServers(mx.Client client) async {
  final network = routeTransportOf(client.httpClient);
  if (network == null || network.coordinator == null) {
    final credentials = await client.getTurnServer();
    return [
      {
        'urls': credentials.uris.map((u) => u.toString()).toList(),
        'username': credentials.username,
        'credential': credentials.password,
      },
    ];
  }
  final requestClient = network.fork();
  try {
    final credentials = await mx.MatrixApi(
      homeserver: client.homeserver,
      accessToken: client.accessToken,
      httpClient: requestClient,
    ).getTurnServer().timeout(const Duration(seconds: 5));
    return verifiedTurnServers(credentials, network.coordinator!.config);
  } finally {
    requestClient.close();
  }
}

lk.Room routedMediaRoom(
  mx.Client client,
  String canonicalUrl,
  lk.RoomOptions options, {
  required bool Function() canRecover,
}) {
  final network = routeTransportOf(client.httpClient);
  if (network == null || network.coordinator == null) {
    return lk.Room(roomOptions: options);
  }
  return lk.Room(
    roomOptions: options,
    engine: RoutedLiveKitEngine(
      network: network,
      canonicalUrl: canonicalUrl,
      loadOptions: () => routedMediaOptions(client),
      canRecover: canRecover,
      roomOptions: options,
    ),
  );
}

Future<lk.ConnectOptions> routedMediaOptions(mx.Client client) async {
  final network = routeTransportOf(client.httpClient);
  if (network == null || network.coordinator == null) {
    return const lk.ConnectOptions(autoSubscribe: false);
  }
  final servers = await mediaIceServers(client);
  return lk.ConnectOptions(
    autoSubscribe: false,
    rtcConfiguration: lk.RTCConfiguration(
      iceServers: servers
          .map(
            (s) => lk.RTCIceServer(
              urls: s['urls'],
              username: s['username'],
              credential: s['credential'],
            ),
          )
          .toList(),
    ),
  );
}
