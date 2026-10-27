import 'dart:js_interop';
import 'package:web/web.dart' as web;

// Browser quota covers temporary encrypted blocks, not the user's Downloads folder.
int p2pRequiredBytes(int bytes) => (bytes * 1.05).ceil() + 64 * 1024 * 1024;

Future<int?> p2pAvailableBytes() async {
  final estimate = await web.window.navigator.storage.estimate().toDart;
  final quota = estimate.quota, usage = estimate.usage;
  return (quota - usage).clamp(0, quota);
}
