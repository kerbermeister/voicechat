import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A short-lived, local image; never persisted with the message or outbox.
class MessageSnapshot {
  final ui.Image image;
  final Rect rect;
  DateTime? expiresAt;
  bool get expired => expiresAt?.isAfter(DateTime.now()) == false;
  MessageSnapshot(this.image, this.rect);
  MessageSnapshot clone() =>
      MessageSnapshot(image.clone(), rect)..expiresAt = expiresAt;
  void dispose() => image.dispose();

  static Future<MessageSnapshot?> capture(GlobalKey key) async {
    final boundary = key.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || boundary.debugNeedsPaint) {
      return null;
    }
    try {
      final rect = boundary.localToGlobal(Offset.zero) & boundary.size;
      return MessageSnapshot(await boundary.toImage(pixelRatio: 1.5), rect);
    } catch (_) {
      // A renderer without snapshots still keeps the normal message transition.
      return null;
    }
  }

  Future<void> animate(
    BuildContext context,
    AnimationController motion, {
    GlobalKey? destination,
    bool deleting = false,
  }) async {
    if (!context.mounted ||
        expired ||
        MediaQuery.disableAnimationsOf(context)) {
      return;
    }
    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject()! as RenderBox;
    Rect local(Rect value) => Rect.fromPoints(
      overlayBox.globalToLocal(value.topLeft),
      overlayBox.globalToLocal(value.bottomRight),
    );
    final source = local(rect);
    final entry = OverlayEntry(
      builder: (_) => AnimatedBuilder(
        animation: motion,
        builder: (_, _) {
          if (expired) return const SizedBox.shrink();
          final t = Curves.easeInOutCubic.transform(motion.value);
          final box = destination?.currentContext?.findRenderObject();
          final target = box is RenderBox && box.attached && box.hasSize
              ? local(box.localToGlobal(Offset.zero) & box.size)
              : source.translate(0, -28);
          return Positioned.fromRect(
            rect: deleting ? source : Rect.lerp(source, target, t)!,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Opacity(
                  opacity: 1 - t,
                  child: Transform.translate(
                    offset: deleting ? Offset(24 * t, 36 * t) : Offset.zero,
                    child: Transform.rotate(
                      angle: deleting ? .08 * t : 0,
                      child: Transform.scale(
                        scale: deleting ? 1 - .85 * t : 1,
                        alignment: Alignment.bottomRight,
                        child: RawImage(image: image, fit: BoxFit.fill),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    try {
      overlay.insert(entry);
      await motion.forward(from: 0).orCancel;
    } on TickerCanceled {
      // Leaving the room must not keep an overlay or delay the actual operation.
    } finally {
      entry.remove();
      entry.dispose();
    }
  }
}

class MessageMenuHighlight extends StatelessWidget {
  final bool selected;
  final Widget child;
  const MessageMenuHighlight({
    super.key,
    required this.selected,
    required this.child,
  });
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    duration: Duration(
      milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 180,
    ),
    curve: Curves.easeOutCubic,
    tween: Tween(begin: 0, end: selected ? 1 : 0),
    child: child,
    builder: (context, value, child) => CustomPaint(
      foregroundPainter: _MenuHighlightPainter(
        Theme.of(context).colorScheme.tertiary,
        value,
      ),
      child: child,
    ),
  );
}

class _MenuHighlightPainter extends CustomPainter {
  final Color color;
  final double strength;
  _MenuHighlightPainter(this.color, this.strength);
  @override
  void paint(Canvas canvas, Size size) {
    if (strength == 0) return;
    final outline = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(1),
      const Radius.circular(22),
    );
    canvas.drawRRect(
      outline,
      Paint()..color = color.withValues(alpha: .12 * strength),
    );
    canvas.drawRRect(
      outline,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: .9 * strength),
    );
  }

  @override
  bool shouldRepaint(_MenuHighlightPainter old) =>
      color != old.color || strength != old.strength;
}
