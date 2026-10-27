import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Interpolates between player/recorder updates using a monotonic clock.
class SmoothProgressRing extends StatefulWidget {
  final double value;
  final bool running;
  final Duration duration;
  final double speed, strokeWidth;
  const SmoothProgressRing({
    super.key,
    required this.value,
    required this.running,
    required this.duration,
    this.speed = 1,
    this.strokeWidth = 4,
  });
  @override
  State<SmoothProgressRing> createState() => _SmoothProgressRingState();
}

class _SmoothProgressRingState extends State<SmoothProgressRing>
    with SingleTickerProviderStateMixin {
  late final ticker = createTicker((elapsed) {
    _elapsed = elapsed;
    if (mounted) setState(() {});
  });
  Duration _elapsed = Duration.zero, _anchorTime = Duration.zero;
  late double anchor = widget.value;
  double get value =>
      (anchor +
              (widget.running && widget.duration.inMicroseconds > 0
                  ? (_elapsed - _anchorTime).inMicroseconds /
                        widget.duration.inMicroseconds *
                        widget.speed
                  : 0))
          .clamp(0.0, 1.0);
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    animate();
  }

  @override
  void didUpdateWidget(SmoothProgressRing oldWidget) {
    final previous =
        (anchor +
                (oldWidget.running && oldWidget.duration.inMicroseconds > 0
                    ? (_elapsed - _anchorTime).inMicroseconds /
                          oldWidget.duration.inMicroseconds *
                          oldWidget.speed
                    : 0))
            .clamp(0.0, 1.0);
    super.didUpdateWidget(oldWidget);
    final seek =
        widget.value < oldWidget.value - .02 ||
        (widget.value - previous).abs() * widget.duration.inMilliseconds > 1000;
    anchor = seek ? widget.value : math.max(previous, widget.value);
    _anchorTime = _elapsed;
    animate();
  }

  void animate() {
    final active = widget.running && !MediaQuery.disableAnimationsOf(context);
    if (active && !ticker.isActive) {
      _elapsed = _anchorTime = Duration.zero;
      ticker.start();
    }
    if (!active && ticker.isActive) {
      ticker.stop();
    }
  }

  @override
  Widget build(BuildContext context) =>
      CircularProgressIndicator(value: value, strokeWidth: widget.strokeWidth);
  @override
  void dispose() {
    ticker.dispose();
    super.dispose();
  }
}
