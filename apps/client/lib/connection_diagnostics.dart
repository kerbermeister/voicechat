import 'screen_controller.dart';
import 'call_probe.dart';
import 'direct_call.dart';
import 'route_coordinator.dart';
import 'voice_call.dart';

/// Local allowlisted snapshot: never serialize sessions, SDP, keys or peer IDs.
Future<Map<String, Object?>> connectionDiagnostics(
  RouteCoordinator? routes,
  VoiceCall? call, {
  ScreenShareController? screen,
}) async {
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
  if (call is DirectCall && call.qualitySamples.isNotEmpty) {
    (result['call'] as Map<String, Object?>)['recent_quality'] =
        call.qualitySamples;
  }
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
        media['video_receiver'] = await call.receivedVideoStatistics().timeout(
          const Duration(seconds: 2),
        );
      } else if (call is CallProbe) {
        media['connection'] = call.media?.connectionState.name;
      }
    } catch (_) {
      media['statistics'] = 'unavailable';
    }
  }
  if (call is CallProbe && call.mediaHistory.isNotEmpty) {
    (result['call'] as Map<String, Object?>)['recent_media'] =
        call.mediaHistory;
  }
  if (screen != null && screen.mediaHistory.isNotEmpty) {
    result['screen'] = {'recent_media': screen.mediaHistory};
  }
  return result;
}
