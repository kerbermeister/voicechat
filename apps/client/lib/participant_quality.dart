import 'direct_call.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'voice_call.dart';
import 'call_probe.dart';
import 'call_quality.dart';

CallQuality participantQuality(VoiceCall call, String identity) {
  if (call is! CallProbe) return call.quality;
  final participant = call.media?.remoteParticipants.values
      .where(
        (p) =>
            p.identity == identity || p.identity.split('/').first == identity,
      )
      .firstOrNull;
  final value = identity == call.identity || identity == call.chat.client.userID
      ? call.media?.localParticipant?.connectionQuality
      : participant?.connectionQuality;
  return switch (value) {
    lk.ConnectionQuality.excellent => CallQuality.excellent,
    lk.ConnectionQuality.good => CallQuality.good,
    lk.ConnectionQuality.poor => CallQuality.poor,
    lk.ConnectionQuality.lost => CallQuality.lost,
    _ => CallQuality.unknown,
  };
}

class ParticipantConnectionBadge extends StatelessWidget {
  final CallQuality quality;
  const ParticipantConnectionBadge({super.key, required this.quality});
  @override
  Widget build(BuildContext context) {
    final bars = switch (quality) {
      CallQuality.excellent => 4,
      CallQuality.good => 3,
      CallQuality.poor => 1,
      _ => 0,
    };
    final color = quality == CallQuality.poor || quality == CallQuality.lost
        ? const Color(0xffffb4ab)
        : Colors.white;
    return Tooltip(
      message: quality.label,
      child: Semantics(
        label: quality.label,
        excludeSemantics: true,
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SizedBox(
            width: 24,
            height: 16,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var i = 0; i < 4; i++)
                  Container(
                    width: 4,
                    height: 4.0 + i * 4,
                    decoration: BoxDecoration(
                      color: i < bars ? color : Colors.white30,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

bool? participantMicrophoneMuted(VoiceCall call, String identity) {
  if (identity == call.chat.client.userID ||
      call is CallProbe && identity == call.identity) {
    return call.muted;
  }
  if (call is DirectCall) return call.call.remoteUserMediaStream?.audioMuted;
  if (call is CallProbe) {
    final participant = call.media?.remoteParticipants.values
        .where(
          (p) =>
              p.identity == identity || p.identity.split('/').first == identity,
        )
        .firstOrNull;
    if (participant == null) return null;
    final microphone = participant.audioTrackPublications
        .where((p) => p.source == lk.TrackSource.microphone)
        .firstOrNull;
    return microphone?.muted ?? true;
  }
  return null;
}

class ParticipantStatusBadge extends StatelessWidget {
  final VoiceCall call;
  final String identity;
  const ParticipantStatusBadge({
    super.key,
    required this.call,
    required this.identity,
  });
  @override
  Widget build(BuildContext context) {
    final muted = participantMicrophoneMuted(call, identity);
    final label = muted == null
        ? 'Состояние микрофона неизвестно'
        : muted
        ? 'Микрофон выключен'
        : 'Микрофон включён';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: label,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              muted == null
                  ? Icons.mic_none
                  : muted
                  ? Icons.mic_off
                  : Icons.mic,
              size: 20,
              color: muted == true ? const Color(0xffffb4ab) : Colors.white,
              semanticLabel: label,
            ),
          ),
        ),
        const SizedBox(width: 4),
        ParticipantConnectionBadge(quality: participantQuality(call, identity)),
      ],
    );
  }
}
