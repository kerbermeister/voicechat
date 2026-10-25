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
            ? rtc.RTCVideoView(
                direct.localVideo!,
                mirror: direct.mirrorLocalVideo,
              )
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
          video: track is lk.VideoTrack
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    // Adaptive stream needs a mounted view before it can deliver E2EE frames.
                    lk.VideoTrackRenderer(track, fit: lk.VideoViewFit.contain),
                    if (!trusted)
                      const ColoredBox(
                        color: Colors.black,
                        child: Center(
                          child: Icon(
                            Icons.lock_outline,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                  ],
                )
              : null,
        ));
      }
    }
    Widget tileView(({String identity, Widget? video}) tile) {
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
    }

    final local = tiles
        .where((t) => t.identity.split('/').first == call.chat.client.userID)
        .firstOrNull;
    return CallVideoLayout(
      local: local == null ? null : tileView(local),
      remote: [
        for (final tile in tiles)
          if (tile != local) tileView(tile),
      ],
    );
  }
}

/// Hiding the preview never changes publication or camera capture.
class CallVideoLayout extends StatefulWidget {
  final Widget? local;
  final List<Widget> remote;
  const CallVideoLayout({super.key, this.local, required this.remote});
  @override
  State<CallVideoLayout> createState() => _CallVideoLayoutState();
}

class _CallVideoLayoutState extends State<CallVideoLayout> {
  bool showSelf = true;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final remote = widget.remote;
      return Stack(
        fit: StackFit.expand,
        children: [
          if (remote.length == 1)
            remote.single
          else if (remote.isEmpty)
            const ColoredBox(
              color: Colors.black87,
              child: Center(
                child: Text(
                  'Ждём собеседника',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            )
          else
            GridView.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: constraints.maxWidth < 440
                    ? 1
                    : remote.length > 4
                    ? 3
                    : 2,
                childAspectRatio: 16 / 10,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: remote.length,
              itemBuilder: (_, index) => remote[index],
            ),
          if (widget.local != null && showSelf)
            Positioned(
              right: 8,
              bottom: 8,
              width: (constraints.maxWidth * .24).clamp(56, 112),
              height: (constraints.maxHeight * .28).clamp(40, 140),
              child: IgnorePointer(child: widget.local!),
            ),
          if (widget.local != null)
            Positioned(
              right: 4,
              top: 4,
              child: IconButton.filledTonal(
                tooltip: showSelf ? 'Скрыть своё видео' : 'Показать своё видео',
                onPressed: () => setState(() => showSelf = !showSelf),
                icon: Icon(
                  showSelf
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
            ),
        ],
      );
    },
  );
}
