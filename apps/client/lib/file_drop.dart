export 'file_drop_stub.dart'
    if (dart.library.io) 'file_drop_native.dart'
    if (dart.library.js_interop) 'file_drop_web.dart';
