import 'animated_message_border.dart';
import 'read_after.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

DateTime? messageExpiry(Event event) {
  if (readAfterSeconds(event) != null) {
    return ReadAfterState.of(event.room.client).expiry(event.eventId);
  }
  final ttl =
      event.content['dev.voicechat.ttl_seconds'] ??
      event.originalSource?.content['dev.voicechat.ttl_seconds'];
  return ttl is int && ttl > 0 && ttl <= 86400
      ? event.originServerTs.add(Duration(seconds: ttl))
      : null;
}

bool messageExpired(Event event, {DateTime? now}) =>
    (readAfterSeconds(event) != null &&
        ReadAfterState.of(event.room.client).expired(event.eventId)) ||
    messageExpiry(event)?.isAfter(now ?? DateTime.now()) == false;

bool emptyEncryptedEvent(Event event) {
  final source = event.originalSource ?? event;
  return source.type == EventTypes.Encrypted && source.content.isEmpty;
}

/// Owns only this message's timer and repaint; never animates expired plaintext.
class TemporaryMessage extends StatefulWidget {
  final Event event;
  final Widget child;
  const TemporaryMessage({super.key, required this.event, required this.child});
  @override
  State<TemporaryMessage> createState() => _TemporaryMessageState();
}

class _TemporaryMessageState extends State<TemporaryMessage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );
  Timer? deadline, countdown;
  DateTime? scheduledExpiry;
  bool expired = false, hidden = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    schedule();
  }

  void schedule() {
    deadline?.cancel();
    countdown?.cancel();
    final expiry = messageExpiry(widget.event);
    scheduledExpiry = expiry;
    expired = expiry != null && !expiry.isAfter(DateTime.now());
    hidden = expired;
    if (expiry == null || expired) return;
    deadline = Timer(expiry.difference(DateTime.now()), expire);
    countdown = Timer.periodic(const Duration(seconds: 1), (_) {
      if (messageExpired(widget.event)) {
        expire();
      } else if (mounted) {
        setState(() {});
      }
    });
  }

  void expire() {
    if (!mounted || expired) return;
    deadline?.cancel();
    countdown?.cancel();
    setState(() => expired = true);
    fade.forward(from: 0).whenComplete(() {
      if (mounted) setState(() => hidden = true);
    });
  }

  @override
  void didUpdateWidget(TemporaryMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!expired && scheduledExpiry != messageExpiry(widget.event)) {
      schedule();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && messageExpired(widget.event)) {
      expire();
    }
  }

  @override
  Widget build(BuildContext context) {
    final expiry = messageExpiry(widget.event);
    if (expiry == null && readAfterSeconds(widget.event) == null) {
      return widget.child;
    }
    final colors = Theme.of(context).colorScheme;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final afterRead = readAfterSeconds(widget.event);
    if (expiry == null) {
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: reduce ? 0 : 500),
        builder: (_, value, child) => Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 10 * (1 - value)),
            child: child,
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: colors.tertiary, width: 2),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.visibility_off_outlined, color: colors.tertiary),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Исчезнет через $afterRead с после прочтения',
                        style: TextStyle(color: colors.tertiary),
                      ),
                    ),
                  ],
                ),
              ),
              widget.child,
            ],
          ),
        ),
      );
    }
    final remaining =
        ((expiry.difference(DateTime.now()).inMilliseconds + 999) ~/ 1000)
            .clamp(0, 86400);
    // The deadline also gates builds after a backgrounded tab's timer was throttled.
    final elapsed = expired || messageExpired(widget.event);
    return RepaintBoundary(
      child: AnimatedSize(
        duration: Duration(milliseconds: reduce ? 0 : 250),
        alignment: Alignment.topCenter,
        child: hidden
            ? const SizedBox.shrink()
            : elapsed
            ? AnimatedBuilder(
                animation: fade,
                builder: (_, _) => CustomPaint(
                  painter: reduce
                      ? null
                      : _Evaporation(colors.primary, fade.value),
                  child: SizedBox(
                    height: 52,
                    child: Center(
                      child: ClipRect(
                        child: Align(
                          widthFactor: afterRead == null ? 1 : 1 - fade.value,
                          child: Opacity(
                            opacity: 1 - fade.value,
                            child: Text(
                              afterRead == null
                                  ? 'Сообщение исчезает'
                                  : 'Сообщение уничтожается',
                              style: TextStyle(color: colors.primary),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              )
            : AnimatedMessageBorder(
                radius: 26,
                padding: 8,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 4,
                        horizontal: 10,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedRotation(
                            turns: reduce ? 0 : -remaining / 60,
                            duration: Duration(milliseconds: reduce ? 0 : 600),
                            child: Icon(
                              afterRead == null
                                  ? Icons.hourglass_bottom_rounded
                                  : Icons.visibility_off_outlined,
                              size: 17,
                              color: colors.tertiary,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              'Исчезнет через ${remaining ~/ 60}:${(remaining % 60).toString().padLeft(2, '0')}',
                              style: TextStyle(
                                color: colors.tertiary,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: widget.child,
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    deadline?.cancel();
    countdown?.cancel();
    fade.dispose();
    super.dispose();
  }
}

class _Evaporation extends CustomPainter {
  final Color color;
  final double progress;
  const _Evaporation(this.color, this.progress);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withValues(alpha: (1 - progress) * .7);
    for (var i = 0; i < 24; i++) {
      final x = size.width * (i + .5) / 24 + math.sin(i * 2.4) * progress * 20;
      final y = size.height * .7 - progress * (20 + i % 5 * 6);
      canvas.drawCircle(Offset(x, y), (2 + i % 3) * (1 - progress), paint);
    }
  }

  @override
  bool shouldRepaint(_Evaporation oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
