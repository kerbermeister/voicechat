import 'package:flutter/material.dart';

/// A quiet illustration built from the same colors as the active theme.
class WelcomePanel extends StatelessWidget {
  final bool compact;
  const WelcomePanel({super.key, this.compact = false});
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.all(compact ? 24 : 48),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(colors.primary, Colors.white, .2)!,
            colors.primary,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(Icons.graphic_eq_rounded, color: colors.onPrimary, size: 30),
              const SizedBox(width: 10),
              Text(
                'VoiceChat',
                style: TextStyle(
                  color: colors.onPrimary,
                  fontSize: 23,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.5,
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 20 : 64),
          Text(
            'Ближе, даже\nна расстоянии.',
            style: TextStyle(
              color: colors.onPrimary,
              fontSize: compact ? 30 : 42,
              height: 1.12,
              fontWeight: FontWeight.w700,
              letterSpacing: -1.3,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Разговоры с теми, кто важен.\nВаш голос, ваши люди, ваше пространство.',
            style: TextStyle(
              color: colors.onPrimary,
              fontSize: 15,
              height: 1.6,
            ),
          ),
          if (!compact) ...[
            const SizedBox(height: 48),
            Transform.rotate(
              angle: -.04,
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(26),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .08),
                      blurRadius: 28,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colors.tertiaryContainer,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            Icons.favorite_border_rounded,
                            color: colors.onTertiaryContainer,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Есть минутка поговорить?',
                            style: TextStyle(
                              color: colors.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: colors.primary,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.play_circle_outline,
                            color: colors.onPrimary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: List.generate(
                                25,
                                (i) => Container(
                                  width: 3,
                                  height: 8 + (i * 13 % 27).toDouble(),
                                  decoration: BoxDecoration(
                                    color: colors.onPrimary,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '0:18',
                            style: TextStyle(color: colors.onPrimary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 48),
            Row(
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 16,
                  color: colors.onPrimary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Личное остаётся личным',
                    style: TextStyle(color: colors.onPrimary, fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
