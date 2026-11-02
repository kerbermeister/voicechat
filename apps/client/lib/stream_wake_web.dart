import 'dart:js_interop';
import 'package:web/web.dart' as web;

class StreamWakeLock {
  web.WakeLockSentinel? _sentinel;
  Future<void> set(bool enabled) async {
    final current = _sentinel;
    if (!enabled) {
      _sentinel = null;
      try {
        if (current != null && !current.released) {
          await current.release().toDart;
        }
      } catch (_) {
        /* The document may already have released its lock. */
      }
      return;
    }
    if (current != null && !current.released) return;
    try {
      _sentinel = await web.window.navigator.wakeLock.request('screen').toDart;
    } catch (_) {
      /* Some browsers deny this in background or low-power mode. */
    }
  }
}
