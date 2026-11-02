import 'dart:async';
import 'user_action_error.dart';

Future<void> Function()? _cancel;
Future<void>? _stopping;
bool get hasActiveCapture => _cancel != null || _stopping != null;

void registerCapture(Future<void> Function() cancel) => _cancel = cancel;
void releaseCapture(Future<void> Function() cancel) {
  if (identical(_cancel, cancel)) _cancel = null;
}

Future<void> stopActiveCapture() async {
  final operation = _stopping ??= _stopCaptures();
  try {
    await operation.timeout(const Duration(seconds: 30));
  } catch (_) {
    throw UserActionError(
      'Микрофон или камера ещё освобождаются. Повторите действие.',
    );
  }
}

Future<void> _stopCaptures() async {
  // Publish the shared operation before invoking callbacks, including sync ones.
  await Future<void>.value();
  try {
    while (_cancel != null) {
      final cancel = _cancel!;
      await cancel();
      releaseCapture(cancel);
    }
  } finally {
    _stopping = null;
  }
}
