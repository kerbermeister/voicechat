import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

DateTime? messageExpiry(Event event) {
  final ttl =
      event.content['dev.voicechat.ttl_seconds'] ??
      event.originalSource?.content['dev.voicechat.ttl_seconds'];
  return ttl is int && ttl > 0 && ttl <= 86400
      ? event.originServerTs.add(Duration(seconds: ttl))
      : null;
}

bool messageExpired(Event event, {DateTime? now}) =>
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
    if (messageExpiry(oldWidget.event) != messageExpiry(widget.event)) {
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
    if (expiry == null) return widget.child;
    final colors = Theme.of(context).colorScheme;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final remaining =
        ((expiry.difference(DateTime.now()).inMilliseconds + 999) ~/ 1000)
            .clamp(0, 86400);
    // The deadline also gates builds after a backgrounded tab's timer was throttled.
    final elapsed = expired || !expiry.isAfter(DateTime.now());
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
                      child: Opacity(
                        opacity: 1 - fade.value,
                        child: Text(
                          'Сообщение исчезает',
                          style: TextStyle(color: colors.primary),
                        ),
                      ),
                    ),
                  ),
                ),
              )
            : Container(
                margin: const EdgeInsets.symmetric(vertical: 1),
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  border: Border.all(color: colors.tertiary, width: 2),
                  borderRadius: BorderRadius.circular(26),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
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
                              Icons.hourglass_bottom_rounded,
                              size: 17,
                              color: colors.tertiary,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            'Исчезнет через ${remaining ~/ 60}:${(remaining % 60).toString().padLeft(2, '0')}',
                            style: TextStyle(
                              color: colors.tertiary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    widget.child,
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
