import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;

// Detect the API, not a mobile user-agent: newer systems can add capture support.
bool get browserScreenCaptureSupported =>
    web.window.isSecureContext &&
    web.window.navigator.mediaDevices
        .getProperty<JSAny?>('getDisplayMedia'.toJS)
        .isA<JSFunction>();
