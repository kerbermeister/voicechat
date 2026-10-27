import 'dart:math' as math;
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// WebRTC levels, with interval RMS for implementations that expose energy only.
class AudioLevels {
  final _previous = <String, ({double energy, double duration})>{};
  double local = 0, remote = 0;
  void read(List<StatsReport> reports) {
    local = remote = 0;
    final active = <String>{};
    for (final report in reports) {
      final values = report.values;
      if (values['kind'] != 'audio' && values['mediaType'] != 'audio') continue;
      final incoming =
          report.type == 'inbound-rtp' ||
          report.type == 'track' && values['remoteSource'] == true;
      if (!incoming &&
          report.type != 'media-source' &&
          !(report.type == 'track' && values['remoteSource'] == false)) {
        continue;
      }
      active.add(report.id);
      double? number(String key) {
        final raw = values[key];
        final value = raw is num
            ? raw.toDouble()
            : raw is String && raw.length <= 32
            ? double.tryParse(raw)
            : null;
        return value?.isFinite == true && value! >= 0 ? value : null;
      }

      var level = number('audioLevel');
      final energy = number('totalAudioEnergy');
      final duration = number('totalSamplesDuration');
      if (energy != null && duration != null) {
        final previous = _previous[report.id];
        if (level == null &&
            previous != null &&
            energy >= previous.energy &&
            duration > previous.duration) {
          level = math.sqrt(
            (energy - previous.energy) / (duration - previous.duration),
          );
        }
        _previous[report.id] = (energy: energy, duration: duration);
      } else {
        _previous.remove(report.id);
      }
      final bounded = (level ?? 0).clamp(0.0, 1.0);
      if (incoming) {
        remote = math.max(remote, bounded);
      } else {
        local = math.max(local, bounded);
      }
    }
    _previous.removeWhere((id, _) => !active.contains(id));
  }
}
