import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'call_probe.dart';
import 'direct_call.dart';
import 'participant_quality.dart';
import 'voice_call.dart';

double participantSpeechLevel(VoiceCall call, String identity) {
  if (call.isClosed || participantMicrophoneMuted(call, identity) == true) {
    return 0;
  }
  final own = identity.split('/').first == call.chat.client.userID;
  if (call is DirectCall) {
    return own
        ? call.audioLevels.local
        : identity == call.call.remoteUserId
        ? call.audioLevels.remote
        : 0;
  }
  if (call is CallProbe) {
    final lk.Participant? participant = own
        ? call.media?.localParticipant
        : call.media?.remoteParticipants.values
              .where(
                (p) =>
                    p.identity == identity ||
                    p.identity.split('/').first == identity,
              )
              .firstOrNull;
    if (participant?.isSpeaking != true) return 0;
    final level = participant!.audioLevel;
    return level.isFinite ? level.clamp(0.0, 1.0) : 0;
  }
  return 0;
}

/// Samples existing media statistics only while an avatar is visible.
class SpeakingAvatar extends StatefulWidget {
  final VoiceCall? call;
  final String identity;
  final bool enabled;
  final Widget child;
  const SpeakingAvatar({
    super.key,
    required this.call,
    required this.identity,
    required this.child,
    this.enabled = true,
  });
  @override
  State<SpeakingAvatar> createState() => _SpeakingAvatarState();
}

class _SpeakingAvatarState extends State<SpeakingAvatar> {
  Timer? timer;
  double level = 0;
  @override
  void initState() {
    super.initState();
    start();
  }

  @override
  void didUpdateWidget(SpeakingAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.call != oldWidget.call ||
        widget.enabled != oldWidget.enabled ||
        widget.identity != oldWidget.identity) {
      level = 0;
      start();
    }
  }

  void start() {
    timer?.cancel();
    if (widget.enabled && widget.call != null) {
      timer = Timer.periodic(
        const Duration(milliseconds: 150),
        (_) => unawaited(sample()),
      );
    }
  }

  Future<void> sample() async {
    final call = widget.call;
    if (call is DirectCall) await call.pollAudioLevels();
    if (!mounted || call != widget.call || !widget.enabled || call == null) {
      return;
    }
    final raw = participantSpeechLevel(call, widget.identity);
    final next = raw < .008 ? 0.0 : (math.sqrt(raw) * 2.5).clamp(0.0, 1.0);
    if ((next - level).abs() > .01) setState(() => level = next);
  }

  @override
  Widget build(BuildContext context) =>
      SpeechRing(level: level, child: widget.child);
  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }
}

class SpeechRing extends StatelessWidget {
  final double level;
  final Widget child;
  const SpeechRing({super.key, required this.level, required this.child});
  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: reduced ? (level > 0 ? 1 : 0) : level),
      duration: reduced ? Duration.zero : const Duration(milliseconds: 120),
      child: child,
      builder: (_, value, child) => CustomPaint(
        foregroundPainter: _SpeechPainter(
          Theme.of(context).colorScheme.primary,
          value,
          !reduced,
        ),
        child: child,
      ),
    );
  }
}

class _SpeechPainter extends CustomPainter {
  final Color color;
  final double strength;
  final bool glow;
  _SpeechPainter(this.color, this.strength, this.glow);
  @override
  void paint(Canvas canvas, Size size) {
    if (strength <= 0) return;
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 + 2;
    if (glow) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = color.withValues(alpha: strength * .4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 + strength * 5
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = color.withValues(alpha: .35 + .65 * strength)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 + strength * 2,
    );
  }

  @override
  bool shouldRepaint(_SpeechPainter old) =>
      color != old.color || strength != old.strength || glow != old.glow;
}
