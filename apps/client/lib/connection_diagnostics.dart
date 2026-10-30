import 'call_probe.dart';
import 'direct_call.dart';
import 'route_coordinator.dart';
import 'voice_call.dart';

/// Local allowlisted snapshot: never serialize sessions, SDP, keys or peer IDs.
Future<Map<String, Object?>> connectionDiagnostics(
  RouteCoordinator? routes,
  VoiceCall? call,
) async {
  final result = <String, Object?>{
    'schema': 1,
    'routing': routes?.diagnostics() ?? {'state': 'canonical'},
    'call': call == null || call.isClosed
        ? {'state': 'inactive'}
        : {
            'state': 'active',
            'kind': call is DirectCall ? 'direct' : 'group',
            'quality': call.quality.name,
            'duration_ms': call.duration.inMilliseconds,
            'microphone_muted': call.muted,
            'camera_enabled': call.cameraEnabled,
          },
  };
  if (call != null && !call.isClosed) {
    final media = result['call'] as Map<String, Object?>;
    try {
      if (call is DirectCall) {
        media['audio_packets_received'] = await call
            .receivedAudioPackets()
            .timeout(const Duration(seconds: 2));
        media['secure_turn_relay'] = await call.hasSecureRelay().timeout(
          const Duration(seconds: 2),
        );
      } else if (call is CallProbe) {
        media['connection'] = call.media?.connectionState.name;
      }
    } catch (_) {
      media['statistics'] = 'unavailable';
    }
  }
  return result;
}
