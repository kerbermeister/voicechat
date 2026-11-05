import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// Associate native call audio/video by participant without changing track IDs.
/// LiveKit otherwise assigns one MediaStream per track, preventing WebRTC sync.
rtc.RTCSessionDescription synchronizeCallStreams(
  rtc.RTCSessionDescription description,
) {
  final sdp = description.sdp;
  if (description.type != 'offer' || sdp == null) return description;
  final streams = <String, String>{};
  final msid = RegExp(
    r'^(a=(?:ssrc:[0-9]+ )?msid:)(PA_[A-Za-z0-9]+\|TR_[A-Za-z0-9_]+) ([^\r\n]+)(\r?)$',
    multiLine: true,
  );
  final ambiguous = <String>{};
  final participantTracks = <String, Map<String, Set<String>>>{};
  final inactiveStreams = <String>{};
  for (final section in sdp.split(RegExp(r'(?=^m=)', multiLine: true))) {
    final media = RegExp(r'^m=(audio|video) ([0-9]+) ').firstMatch(section);
    if (media == null) continue;
    final inactive =
        media[2] == '0' ||
        RegExp(
          r'^a=(inactive|recvonly)\r?$',
          multiLine: true,
        ).hasMatch(section);
    for (final match in msid.allMatches(section)) {
      if (inactive) {
        inactiveStreams.add(match[2]!);
        continue;
      }
      final participant = match[2]!.split('|').first;
      participantTracks
          .putIfAbsent(participant, () => {})
          .putIfAbsent(media[1]!, () => {})
          .add(match[3]!);
    }
  }
  // WebRTC Call::ConfigureSync supports only one A/V pair per sync group.
  // Multiple camera/screen/audio sources retain their original associations.
  final multipleSources = {
    for (final entry in participantTracks.entries)
      if (entry.value.values.any((tracks) => tracks.length > 1)) entry.key,
  };
  for (final match in msid.allMatches(sdp)) {
    final stream = match[2]!;
    if (stream.split('|')[1] != match[3]) ambiguous.add(stream);
  }
  final grouped = sdp.replaceAllMapped(msid, (match) {
    final stream = match[2]!;
    final parts = stream.split('|');
    // Unknown server formats stay untouched; the SDK needs the actual track ID
    // for publication lookup and participant-specific frame encryption.
    if (stream.length > 64 ||
        ambiguous.contains(stream) ||
        inactiveStreams.contains(stream) ||
        multipleSources.contains(parts[0])) {
      return match[0]!;
    }
    final group = '${parts[0]}|voicechat-call';
    if (group.length > 64) return match[0]!;
    streams[stream] = group;
    return '${match[1]}$group ${match[3]}${match[4]}';
  });
  if (streams.isEmpty) return description;
  // Most offers use WMS *. Preserve explicit stream lists as well.
  final result = grouped.replaceAllMapped(
    RegExp(r'^(a=msid-semantic: WMS )([^\r\n]+)(\r?)$', multiLine: true),
    (match) =>
        '${match[1]}${match[2]!.split(' ').map((id) => streams[id] ?? id).toSet().join(' ')}${match[3]}',
  );
  return rtc.RTCSessionDescription(result, description.type);
}
