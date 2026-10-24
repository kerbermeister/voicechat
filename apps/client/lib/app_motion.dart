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

/// Keeps optional panels in the flow while they quickly fade and expand.
class AnimatedPanel extends StatelessWidget {
  final Widget? child;
  const AnimatedPanel({super.key, this.child});

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
          child: content,
        ),
      ),
      child: FadeTransition(
        opacity: animation,
        child: SizeTransition(
          sizeFactor: animation,
          alignment: Alignment.bottomCenter,
          child: child,
        ),
      ),
    ),
    child: child == null
        ? const SizedBox.shrink(key: ValueKey('hidden'))
        : KeyedSubtree(
            key: child!.key ?? const ValueKey('visible'),
            child: child!,
          ),
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
