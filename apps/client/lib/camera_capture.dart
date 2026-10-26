import 'call_quality.dart';
export 'camera_capture_native.dart'
    if (dart.library.js_interop) 'camera_capture_web.dart';

Map<String, dynamic> cameraConstraints(String facing, VideoQuality quality) => {
  'audio': false,
  'video': {
    'facingMode': {facing == 'environment' ? 'exact' : 'ideal': facing},
    'width': {'ideal': quality.width},
    'height': {'ideal': quality.height},
    'frameRate': {'ideal': quality.fps},
  },
};
