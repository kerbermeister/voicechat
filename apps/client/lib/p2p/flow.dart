import 'package:flutter/material.dart';

/// Decorative packet movement is driven by confirmed traffic, never a fake loader.
class P2pFlow extends StatefulWidget {
  final bool moving, complete, outgoing;
  const P2pFlow({
    super.key,
    required this.moving,
    required this.complete,
    required this.outgoing,
  });
  @override
  State<P2pFlow> createState() => _P2pFlowState();
}

class _P2pFlowState extends State<P2pFlow> with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  void sync() {
    final run =
        widget.moving &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (run && !controller.isAnimating) {
      controller.repeat();
    } else if (!run) {
      controller.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    sync();
  }

  @override
  void didUpdateWidget(P2pFlow old) {
    super.didUpdateWidget(old);
    sync();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            _endpoint(
              widget.outgoing ? 'Вы' : 'Отправитель',
              Icons.person_outline,
              color,
            ),
            Expanded(
              child: SizedBox(
                height: 48,
                child: AnimatedBuilder(
                  animation: controller,
                  builder: (_, __) => CustomPaint(
                    painter: _PacketPainter(
                      color,
                      controller.value,
                      widget.moving,
                      widget.complete,
                    ),
                  ),
                ),
              ),
            ),
            _endpoint(
              widget.outgoing ? 'Получатель' : 'Вы',
              widget.complete
                  ? Icons.check_circle_outline
                  : Icons.person_outline,
              color,
            ),
          ],
        ),
      ),
    );
  }

  Widget _endpoint(String name, IconData icon, Color color) => Column(
    children: [
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: .1),
        ),
        child: Icon(icon, color: color, size: 20),
      ),
      const SizedBox(height: 4),
      Text(name, style: Theme.of(context).textTheme.labelSmall),
    ],
  );
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

class _PacketPainter extends CustomPainter {
  final Color color;
  final double phase;
  final bool moving, complete;
  _PacketPainter(this.color, this.phase, this.moving, this.complete);
  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height * .35, start = 8.0, end = size.width - 8;
    if (end <= start) return;
    final paint = Paint()
      ..color = color.withValues(alpha: complete ? .65 : .2)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(start, y), Offset(end, y), paint);
    canvas.drawLine(Offset(end - 5, y - 4), Offset(end, y), paint);
    canvas.drawLine(Offset(end - 5, y + 4), Offset(end, y), paint);
    if (!moving) return;
    for (var i = 0; i < 3; i++) {
      final p = (phase + i / 3) % 1;
      final x = start + (end - start) * p;
      canvas.drawCircle(
        Offset(x, y),
        6,
        Paint()..color = color.withValues(alpha: .12),
      );
      canvas.drawCircle(Offset(x, y), 3, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_PacketPainter old) =>
      old.phase != phase ||
      old.moving != moving ||
      old.complete != complete ||
      old.color != color;
}
