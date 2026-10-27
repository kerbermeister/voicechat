import 'package:flutter/material.dart';

class ActiveCallBanner extends StatefulWidget {
  final String label;
  final VoidCallback onPressed;
  const ActiveCallBanner({
    super.key,
    required this.label,
    required this.onPressed,
  });
  @override
  State<ActiveCallBanner> createState() => _ActiveCallBannerState();
}

class _ActiveCallBannerState extends State<ActiveCallBanner>
    with SingleTickerProviderStateMixin {
  late final pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      pulse.stop();
      pulse.value = 0;
    } else if (!pulse.isAnimating) {
      pulse.repeat(reverse: true);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    child: AnimatedBuilder(
      animation: pulse,
      builder: (_, _) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              Color.lerp(
                const Color(0xff5145a5),
                const Color(0xff6856b9),
                pulse.value,
              )!,
              const Color(0xff245a91),
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(
                0xff615ed4,
              ).withValues(alpha: .16 + pulse.value * .14),
              blurRadius: 7,
            ),
          ],
        ),
        child: TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          onPressed: widget.onPressed,
          icon: const Icon(Icons.call),
          label: Text(widget.label, textAlign: TextAlign.center),
        ),
      ),
    ),
  );
  @override
  void dispose() {
    pulse.dispose();
    super.dispose();
  }
}
