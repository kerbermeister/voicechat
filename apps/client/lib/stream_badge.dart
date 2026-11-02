import 'package:flutter/material.dart';

/// A distinct live indicator; the underlying profile image stays unchanged.
class LiveStreamBadge extends StatefulWidget {
  final VoidCallback onTap;
  const LiveStreamBadge({super.key, required this.onTap});
  @override
  State<LiveStreamBadge> createState() => _LiveStreamBadgeState();
}

class _LiveStreamBadgeState extends State<LiveStreamBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController pulse = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      pulse.stop();
      pulse.value = 1;
    } else {
      pulse.repeat(reverse: true);
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Идёт стрим. Информация и просмотр',
    child: Tooltip(
      message: 'Идёт стрим',
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedBuilder(
          animation: pulse,
          builder: (context, _) => Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(
                  context,
                ).colorScheme.error.withValues(alpha: .6 + .4 * pulse.value),
                width: 2,
              ),
              borderRadius: BorderRadius.circular(18),
            ),
            alignment: Alignment.topRight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.error,
                shape: BoxShape.circle,
              ),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.sensors, size: 16, color: Colors.white),
              ),
            ),
          ),
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
