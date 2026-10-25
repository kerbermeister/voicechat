import 'package:flutter/material.dart';
import 'app_motion.dart';

bool compactAuthHeight(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.height < (size.width < 900 ? 800 : 700);
}

/// Shared authentication surface; one scroll region keeps forms above keyboards.
class AuthPage extends StatelessWidget {
  final String title, subtitle, eyebrow;
  final IconData icon;
  final Widget child;
  final Widget? trailing;
  final VoidCallback? onBack;
  final double maxWidth;
  const AuthPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.eyebrow,
    required this.icon,
    required this.child,
    this.trailing,
    this.onBack,
    this.maxWidth = 500,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colors.surface,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(.7, -.6),
            radius: 1.3,
            colors: [
              colors.secondaryContainer.withValues(alpha: .75),
              colors.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) {
              final compact = box.maxWidth < 600;
              final short = compactAuthHeight(context);
              final headerHeight =
                  (MediaQuery.textScalerOf(
                    context,
                  ).scale(24)).clamp(48.0, double.infinity) +
                  8;
              return SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: box.maxWidth,
                    minHeight: box.maxHeight,
                  ),
                  child: Center(
                    child: Column(
                      key: const ValueKey('auth-content'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: headerHeight,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: maxWidth + 48,
                            ),
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(
                                compact ? 16 : 24,
                                4,
                                compact ? 16 : 24,
                                4,
                              ),
                              child: Row(
                                children: [
                                  if (onBack != null)
                                    IconButton(
                                      tooltip: 'Вернуться ко входу',
                                      onPressed: onBack,
                                      icon: const Icon(
                                        Icons.arrow_back_rounded,
                                      ),
                                    ),
                                  Icon(
                                    Icons.graphic_eq_rounded,
                                    color: colors.primary,
                                  ),
                                  const SizedBox(width: 10),
                                  const Expanded(
                                    child: Text(
                                      'VoiceChat',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  if (trailing != null) trailing!,
                                ],
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: compact ? 12 : 24,
                          ),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: maxWidth),
                            child: Material(
                              key: const ValueKey('auth-card'),
                              color: colors.surfaceContainerLowest,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(28),
                                side: BorderSide(
                                  color: colors.outlineVariant.withValues(
                                    alpha: .7,
                                  ),
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Padding(
                                padding: EdgeInsets.all(
                                  short
                                      ? 8
                                      : compact
                                      ? 16
                                      : 24,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (!short)
                                      Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.all(6),
                                            decoration: BoxDecoration(
                                              color: colors.secondaryContainer,
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                            ),
                                            child: Icon(
                                              icon,
                                              color: colors.primary,
                                              size: 20,
                                            ),
                                          ),
                                          const SizedBox(width: 14),
                                          Expanded(
                                            child: Text(
                                              eyebrow,
                                              style: TextStyle(
                                                color: colors.primary,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w500,
                                                letterSpacing: 1.2,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    SizedBox(height: short ? 0 : 12),
                                    Semantics(
                                      header: true,
                                      child: Text(
                                        title,
                                        style: TextStyle(
                                          fontSize: short ? 24 : 28,
                                          height: 1.15,
                                          fontWeight: FontWeight.w500,
                                          letterSpacing: -.7,
                                        ),
                                      ),
                                    ),
                                    if (!short) const SizedBox(height: 6),
                                    if (!short)
                                      Text(
                                        subtitle,
                                        style: TextStyle(
                                          color: colors.onSurfaceVariant,
                                          fontSize: 14,
                                          height: 1.4,
                                        ),
                                      ),
                                    SizedBox(height: short ? 8 : 16),
                                    FilledButtonTheme(
                                      data: FilledButtonThemeData(
                                        style: Theme.of(context)
                                            .filledButtonTheme
                                            .style
                                            ?.copyWith(
                                              padding: short
                                                  ? const WidgetStatePropertyAll(
                                                      EdgeInsets.symmetric(
                                                        horizontal: 22,
                                                        vertical: 12,
                                                      ),
                                                    )
                                                  : null,
                                            ),
                                      ),
                                      child: child,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Balance the header so the card itself is centered.
                        SizedBox(height: headerHeight),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class AuthField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String? helper, error;
  final bool secret, readOnly;
  final TextInputType? keyboardType;
  final Iterable<String>? autofillHints;
  final String? Function(String?)? validator;
  final VoidCallback? onSubmitted;
  const AuthField({
    super.key,
    required this.controller,
    required this.label,
    this.helper,
    this.error,
    this.secret = false,
    this.readOnly = false,
    this.keyboardType,
    this.autofillHints,
    this.validator,
    this.onSubmitted,
  });
  @override
  State<AuthField> createState() => _AuthFieldState();
}

class _AuthFieldState extends State<AuthField> {
  bool revealed = false;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: compactAuthHeight(context) ? 6 : 8),
    child: TextFormField(
      controller: widget.controller,
      readOnly: widget.readOnly,
      obscureText: widget.secret && !revealed,
      autocorrect: false,
      enableSuggestions: !widget.secret,
      keyboardType: widget.keyboardType,
      autofillHints: widget.autofillHints,
      textInputAction: widget.onSubmitted == null
          ? TextInputAction.next
          : TextInputAction.done,
      onFieldSubmitted: (_) => widget.onSubmitted?.call(),
      validator: widget.validator,
      style: const TextStyle(fontSize: 16),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        labelText: widget.label,
        helperText: widget.helper,
        helperMaxLines: 4,
        errorText: widget.error,
        errorMaxLines: 4,
        fillColor: Theme.of(context).colorScheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        suffixIcon: widget.secret
            ? IconButton(
                tooltip: revealed ? 'Скрыть пароль' : 'Показать пароль',
                onPressed: () => setState(() => revealed = !revealed),
                icon: Icon(
                  revealed
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              )
            : null,
      ),
    ),
  );
}

class AuthNotice extends StatelessWidget {
  final String text;
  final bool error;
  final IconData icon;
  const AuthNotice(
    this.text, {
    super.key,
    this.error = false,
    this.icon = Icons.info_outline,
  });
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = error
        ? colors.onErrorContainer
        : colors.onSurfaceVariant;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: error ? colors.errorContainer : colors.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              error ? Icons.error_outline : icon,
              color: foreground,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: foreground, fontSize: 13, height: 1.35),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cross-fades complete stages without animating individual form fields.
class AuthStage extends StatelessWidget {
  final Widget child;
  const AuthStage({super.key, required this.child});
  @override
  Widget build(BuildContext context) => MediaQuery.disableAnimationsOf(context)
      ? child
      : AnimatedSize(
          duration: motionDuration(context),
          alignment: Alignment.topCenter,
          curve: Curves.easeOutCubic,
          child: AnimatedSwitcher(
            duration: motionDuration(context),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: animation.drive(
                  Tween(begin: const Offset(0, .025), end: Offset.zero),
                ),
                child: IgnorePointer(
                  ignoring: animation.status == AnimationStatus.reverse,
                  child: ExcludeFocus(
                    excluding: animation.status == AnimationStatus.reverse,
                    child: child,
                  ),
                ),
              ),
            ),
            child: child,
          ),
        );
}
