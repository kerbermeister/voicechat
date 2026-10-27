import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'call_probe.dart';
import 'direct_call.dart';
import 'voice_call.dart';
import 'call_audio_platform.dart';

/// Local receiver gain only; never changes another participant's microphone.
class CallAudio {
  final levels = <String, double>{};
  final _applied = <rtc.MediaStreamTrack, double>{};
  VoiceCall? _call;
  bool _syncing = false;
  double level(String user) => levels[user] ?? 1;
  Set<String> people(VoiceCall call) => call.participants
      .map((id) => id.split('/').first)
      .where((id) => id.isNotEmpty && id != call.chat.client.userID)
      .toSet();

  Future<void> set(VoiceCall call, String user, double value) async {
    if (!value.isFinite ||
        value < 0 ||
        value > 3 ||
        !people(call).contains(user)) {
      throw ArgumentError('Invalid receiver volume');
    }
    if (_call != call) reset(call);
    levels[user] = value;
    await sync(call);
  }

  void reset(VoiceCall? call) {
    for (final track in _applied.keys) {
      if (track.id != null) forgetCallTrackVolume(track.id!);
    }
    _applied.clear();
    levels.clear();
    _call = call;
  }

  Future<void> sync(VoiceCall? call) async {
    if (_call != call) reset(call);
    if (_syncing || call == null || call.isClosed) return;
    _syncing = true;
    try {
      final tracks = <({String user, rtc.MediaStreamTrack track})>[];
      if (call is DirectCall && call.call.remoteUserId != null) {
        for (final stream in call.call.getRemoteStreams) {
          for (final track
              in stream.stream?.getAudioTracks() ?? <rtc.MediaStreamTrack>[]) {
            tracks.add((user: call.call.remoteUserId!, track: track));
          }
        }
      } else if (call is CallProbe) {
        for (final participant
            in call.media?.remoteParticipants.values ??
                <lk.RemoteParticipant>[]) {
          for (final publication in participant.audioTrackPublications) {
            final track = publication.track?.mediaStreamTrack;
            if (track != null) {
              tracks.add((
                user: participant.identity.split('/').first,
                track: track,
              ));
            }
          }
        }
      }
      for (final item in tracks) {
        while (_applied[item.track] != level(item.user)) {
          final value = level(item.user);
          await setCallTrackVolume(item.track, value);
          if (_call != call || call.isClosed) return;
          _applied[item.track] = value;
        }
      }
      _applied.removeWhere((track, _) {
        if (tracks.any((item) => item.track == track)) return false;
        if (track.id != null) forgetCallTrackVolume(track.id!);
        return true;
      });
    } finally {
      _syncing = false;
    }
  }
}
