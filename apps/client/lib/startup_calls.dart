import 'dart:async';
import 'package:matrix/matrix.dart';

/// init/login can sync an invite before the UI has installed its VoIP delegate.
class StartupCalls {
  final _events = <BasicEventWithSender>[];
  late final StreamSubscription<List<BasicEventWithSender>> _subscription;
  StartupCalls(Stream<List<BasicEventWithSender>> events) {
    _subscription = events.listen((events) {
      _events.addAll(events);
      if (_events.length > 256) {
        _events.removeRange(0, _events.length - 256);
      }
    });
  }

  List<BasicEventWithSender> take() {
    unawaited(_subscription.cancel());
    final events = List<BasicEventWithSender>.of(_events);
    _events.clear();
    return events;
  }

  Future<void> close() => _subscription.cancel();
}
