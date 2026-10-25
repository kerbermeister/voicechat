import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'voice_recording.dart';

// A fixed -60…0 dBFS scale keeps quiet speech visible without auto-normalizing it.
double waveLevel(int rms) => rms <= 0
    ? 0
    : ((20 * log(rms.clamp(1, 1024) / 1024) / ln10 + 60) / 60).clamp(0, 1);

class WaveformView extends StatelessWidget {
  final List<int> levels;
  final double progress;
  final Color? color;
  final bool recording;
  const WaveformView({
    super.key,
    required this.levels,
    this.progress = 0,
    this.color,
    this.recording = false,
  });
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = color ?? colors.primary;
    return Semantics(
      label: recording ? 'Уровень микрофона' : 'Звуковая дорожка сообщения',
      child: Container(
        height: recording ? 84 : 40,
        padding: EdgeInsets.symmetric(
          horizontal: 8,
          vertical: recording ? 6 : 4,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLowest,
          border: Border.all(color: accent.withValues(alpha: .2)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: CustomPaint(
          size: Size(double.infinity, recording ? 72 : 32),
          painter: _WavePainter(levels, progress, accent, recording),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  final List<int> levels;
  final double progress;
  final Color color;
  final bool recording;
  _WavePainter(this.levels, this.progress, this.color, this.recording);
  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final samples = recording
        ? [
            ...List.filled(
              max(0, PcmLevelMeter.historySize - levels.length),
              0,
            ),
            ...levels,
          ]
        : levels;
    if (samples.isEmpty) return;
    final grid = Paint()
      ..color = color.withValues(alpha: .09)
      ..strokeWidth = 1;
    for (final y in [.25, .5, .75]) {
      canvas.drawLine(
        Offset(0, size.height * y),
        Offset(size.width, size.height * y),
        grid,
      );
    }
    final bars = min(samples.length, max(1, (size.width / 7).floor()));
    final step = size.width / bars;
    final paint = Paint()
      ..strokeWidth = min(4, step * .6)
      ..strokeCap = StrokeCap.round;
    final silence = Paint()
      ..color = color.withValues(alpha: .18)
      ..strokeWidth = min(3, step * .6)
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < bars; i++) {
      final start = i * samples.length ~/ bars;
      final end = (i + 1) * samples.length ~/ bars;
      final rms = samples.sublist(start, end).reduce(max);
      final amplitude = max(0.0, waveLevel(rms) * (size.height / 2 - 2));
      final played = (i + .5) / bars <= progress.clamp(0, 1);
      paint.shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: played || recording ? 1 : .85),
          color.withValues(alpha: played || recording ? .9 : .8),
        ],
      ).createShader(Offset.zero & size);
      final x = step * (i + .5);
      canvas.drawLine(
        Offset(x, size.height / 2 - amplitude),
        Offset(x, size.height / 2 + amplitude),
        rms == 0 ? silence : paint,
      );
    }
    if (progress > 0 && progress < 1) {
      canvas.drawCircle(
        Offset(size.width * progress, size.height / 2),
        3.5,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) =>
      !listEquals(levels, oldDelegate.levels) ||
      progress != oldDelegate.progress ||
      recording != oldDelegate.recording ||
      color != oldDelegate.color;
}

class RecordingWaveformPanel extends StatelessWidget {
  final List<int> levels;
  final String label;
  final VoidCallback onCancel, onStop;
  const RecordingWaveformPanel({
    super.key,
    required this.levels,
    required this.label,
    required this.onCancel,
    required this.onStop,
  });
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.all(12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(24),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Icon(Icons.mic, color: Color(0xFFC64250)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            IconButton(
              tooltip: 'Отменить запись',
              onPressed: onCancel,
              icon: const Icon(Icons.delete_outline),
            ),
            IconButton.filled(
              tooltip: 'Остановить запись',
              onPressed: onStop,
              icon: const Icon(Icons.stop),
            ),
          ],
        ),
        WaveformView(levels: levels, recording: true),
      ],
    ),
  );
}
