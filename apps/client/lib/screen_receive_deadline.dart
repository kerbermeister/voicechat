import 'dart:async';

/// Repeated key/track events must not extend an unsuccessful receive attempt.
class ScreenReceiveDeadline {
  final void Function() expired;
  Timer? _timer;
  ScreenReceiveDeadline(this.expired);

  void start() {
    _timer ??= Timer(const Duration(seconds: 20), expired);
  }

  void reset() {
    _timer?.cancel();
    _timer = null;
  }
}
