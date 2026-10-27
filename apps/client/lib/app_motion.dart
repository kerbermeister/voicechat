import 'dart:ui' as ui;
import 'package:flutter/material.dart';

const appMotionDuration = Duration(milliseconds: 180);

Duration motionDuration(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : appMotionDuration;

AnimationStyle appAnimationStyle(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? AnimationStyle.noAnimation
    : const AnimationStyle(
        duration: appMotionDuration,
        reverseDuration: Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );

/// Keep focus, dismissal and typed results; nested windows retain their parent.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  AnimationStyle? animationStyle,
  bool clearBackdrop = false,
}) => showDialog<T>(
  context: context,
  barrierDismissible: barrierDismissible,
  barrierColor: clearBackdrop ? Colors.transparent : null,
  animationStyle: animationStyle ?? appAnimationStyle(context),
  builder: (context) => clearBackdrop
      ? builder(context)
      : AppModalBackdrop(child: builder(context)),
);

class AppDialogTitle extends StatelessWidget {
  final Widget child;
  const AppDialogTitle({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 500;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(width: 44),
        Expanded(
          child: DefaultTextStyle.merge(
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: compact ? 18 : 22,
              fontFamily: Theme.of(context).textTheme.titleLarge?.fontFamily,
            ),
            child: child,
          ),
        ),
        IconButton(
          tooltip: 'Закрыть',
          onPressed: () => Navigator.of(context).maybePop(),
          style: IconButton.styleFrom(
            minimumSize: const Size(44, 44),
            maximumSize: const Size(44, 44),
            padding: const EdgeInsets.all(10),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          icon: const Icon(Icons.close_rounded, size: 22),
        ),
      ],
    );
  }
}

class AppModalBackdrop extends StatelessWidget {
  final Widget child;
  const AppModalBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final animation = MediaQuery.disableAnimationsOf(context)
        ? const AlwaysStoppedAnimation<double>(1)
        : ModalRoute.of(context)?.animation ??
              const AlwaysStoppedAnimation<double>(1);
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final sigma = 5 * Curves.easeOutCubic.transform(animation.value);
        return BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: child,
        );
      },
    );
  }
}

/// Keeps optional panels in the flow while they quickly fade and expand.
class AnimatedPanel extends StatelessWidget {
  final Widget? child;
  final Axis axis;
  const AnimatedPanel({super.key, this.child, this.axis = Axis.vertical});

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: motionDuration(context),
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeInCubic,
    transitionBuilder: (child, animation) => AnimatedBuilder(
      animation: animation,
      builder: (_, content) => IgnorePointer(
        ignoring: animation.status == AnimationStatus.reverse,
        child: ExcludeSemantics(
          excluding: animation.status == AnimationStatus.reverse,
          child: ExcludeFocus(
            excluding: animation.status == AnimationStatus.reverse,
            child: content!,
          ),
        ),
      ),
      child: FadeTransition(
        opacity: animation,
        child: SizeTransition(
          sizeFactor: animation,
          axis: axis,
          alignment: axis == Axis.vertical
              ? Alignment.bottomCenter
              : Alignment.centerRight,
          child: child,
        ),
      ),
    ),
    child: child == null
        ? const SizedBox.shrink(key: ValueKey('hidden'))
        : KeyedSubtree(key: ValueKey(child!.key ?? 'visible'), child: child!),
  );
}

class AppPageTransitions extends PageTransitionsBuilder {
  const AppPageTransitions();
  @override
  Duration get transitionDuration => appMotionDuration;
  @override
  Duration get reverseTransitionDuration => appMotionDuration;
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return FadeTransition(
      opacity: animation.drive(CurveTween(curve: Curves.easeOutCubic)),
      child: child,
    );
  }
}
