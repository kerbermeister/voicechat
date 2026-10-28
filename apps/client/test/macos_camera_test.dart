import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/macos_camera.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final original = CameraPlatform.instance;
  final methods = <String>[];
  setUp(() {
    methods.clear();
    CameraPlatform.instance = MacOSCamera();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MacOSCamera.channel, (call) async {
          methods.add(call.method);
          return switch (call.method) {
            'cameras' => ['built-in'],
            'create' => 42,
            'initialize' => {'width': 1920, 'height': 1080},
            'stop' => '/private/cache/REC123.mp4',
            _ => null,
          };
        });
  });
  tearDown(() {
    CameraPlatform.instance = original;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MacOSCamera.channel, null);
  });

  test(
    'shared CameraController initializes landscape preview and records MP4',
    () async {
      final camera = CameraController(
        (await availableCameras()).single,
        ResolutionPreset.medium,
        enableAudio: true,
      );
      await camera.initialize();
      expect(camera.value.isInitialized, isTrue);
      expect(camera.value.deviceOrientation, DeviceOrientation.landscapeLeft);
      expect(camera.value.previewSize, const Size(1920, 1080));
      expect(camera.value.aspectRatio, closeTo(16 / 9, .001));
      await camera.startVideoRecording();
      expect(camera.value.isRecordingVideo, isTrue);
      final file = await camera.stopVideoRecording();
      expect(file.mimeType, 'video/mp4');
      expect(file.path, endsWith('.mp4'));
      await camera.dispose();
      expect(methods, [
        'cameras',
        'create',
        'initialize',
        'start',
        'stop',
        'dispose',
      ]);
    },
  );

  test(
    'permission denial reaches shared recorder as CameraException',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MacOSCamera.channel, (call) async {
            if (call.method == 'create') return 42;
            if (call.method == 'initialize') {
              throw PlatformException(
                code: 'denied',
                message: 'Camera permission denied',
              );
            }
            return null;
          });
      final camera = CameraController(
        const CameraDescription(
          name: 'built-in',
          lensDirection: CameraLensDirection.external,
          sensorOrientation: 0,
        ),
        ResolutionPreset.medium,
      );
      await expectLater(camera.initialize(), throwsA(isA<CameraException>()));
      expect(camera.value.isInitialized, isFalse);
      await camera.dispose();
    },
  );
}
