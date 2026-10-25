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
  final cancel = _cancel;
  if (cancel == null) return;
  final operation = _stopping ??= cancel();
  unawaited(
    operation.then(
      (_) {
        releaseCapture(cancel);
        if (identical(_stopping, operation)) _stopping = null;
      },
      onError: (Object _) {
        if (identical(_stopping, operation)) _stopping = null;
      },
    ),
  );
  try {
    await operation.timeout(const Duration(seconds: 30));
  } catch (_) {
    throw UserActionError(
      'Микрофон или камера ещё освобождаются. Повторите действие.',
    );
  }
}
