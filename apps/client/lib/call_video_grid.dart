import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'call_probe.dart';
import 'direct_call.dart';
import 'voice_call.dart';

class CallVideoGrid extends StatelessWidget {
  final VoiceCall call;
  const CallVideoGrid({super.key, required this.call});
  @override
  Widget build(BuildContext context) {
    final tiles = <({String identity, Widget? video})>[];
    if (call case DirectCall direct) {
      tiles.add((
        identity: call.chat.client.userID!,
        video: direct.cameraEnabled && direct.localVideo != null
            ? rtc.RTCVideoView(direct.localVideo!, mirror: true)
            : null,
      ));
      tiles.add((
        identity: direct.call.remoteUserId ?? '',
        video:
            direct.remoteVideo == null ||
                direct.call.remoteUserMediaStream?.videoMuted == true
            ? null
            : rtc.RTCVideoView(direct.remoteVideo!),
      ));
    } else if (call case CallProbe group) {
      final participants = <lk.Participant>[
        if (group.media?.localParticipant != null)
          group.media!.localParticipant!,
        ...?group.media?.remoteParticipants.values,
      ];
      for (final participant in participants) {
        final publication = participant.videoTrackPublications
            .where((p) => !p.muted)
            .firstOrNull;
        final track = publication?.track;
        final trusted =
            participant is lk.LocalParticipant ||
            group.decryptedVideoTracks.contains(publication?.sid);
        tiles.add((
          identity: participant.identity,
          video: trusted && track is lk.VideoTrack
              ? lk.VideoTrackRenderer(track, fit: lk.VideoViewFit.contain)
              : null,
        ));
      }
    }
    return LayoutBuilder(
      builder: (context, constraints) => GridView.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: constraints.maxWidth < 440
              ? 1
              : tiles.length > 4
              ? 3
              : 2,
          childAspectRatio: 16 / 10,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: tiles.length,
        itemBuilder: (context, index) {
          final tile = tiles[index];
          final userId = tile.identity.split('/').first;
          final user = call.chat
              .getParticipants()
              .where((u) => u.id == userId)
              .firstOrNull;
          final label = userId == call.chat.client.userID
              ? 'Вы'
              : user?.displayName ?? tile.identity;
          return ClipRRect(
            key: ValueKey(tile.identity),
            borderRadius: BorderRadius.circular(18),
            child: ColoredBox(
              color: Colors.black87,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  tile.video ??
                      const Center(
                        child: Icon(
                          Icons.videocam_off_outlined,
                          color: Colors.white70,
                          size: 32,
                        ),
                      ),
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        backgroundColor: Colors.black54,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
