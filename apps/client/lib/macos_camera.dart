import 'dart:async';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Implements only the camera operations used by the shared video-note recorder.
class MacOSCamera extends CameraPlatform {
  static const channel = MethodChannel('voicechat/camera');
  final _initialized = StreamController<CameraInitializedEvent>.broadcast();
  final _errors = StreamController<CameraErrorEvent>.broadcast();

  MacOSCamera() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'error') {
        final data = Map<String, dynamic>.from(call.arguments as Map);
        _errors.add(
          CameraErrorEvent(data['id'] as int, data['message'] as String),
        );
      }
    });
  }

  @override
  Future<List<CameraDescription>> availableCameras() async => [
    for (final name
        in await channel.invokeListMethod<String>('cameras') ?? <String>[])
      CameraDescription(
        name: name,
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      ),
  ];

  @override
  Future<int> createCamera(
    CameraDescription cameraDescription,
    ResolutionPreset? resolutionPreset, {
    bool enableAudio = false,
  }) async => (await channel.invokeMethod<int>('create', {
    'name': cameraDescription.name,
    'audio': enableAudio,
  }))!;

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    final size = (await channel.invokeMapMethod<String, dynamic>('initialize', {
      'id': cameraId,
    }))!;
    _initialized.add(
      CameraInitializedEvent(
        cameraId,
        (size['width'] as num).toDouble(),
        (size['height'] as num).toDouble(),
        ExposureMode.auto,
        false,
        FocusMode.auto,
        false,
      ),
    );
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      _initialized.stream.where((e) => e.cameraId == cameraId);
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      _errors.stream.where((e) => e.cameraId == cameraId);
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      Stream.value(
        const DeviceOrientationChangedEvent(DeviceOrientation.landscapeLeft),
      );
  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) =>
      channel.invokeMethod<void>('start', {'id': options.cameraId});
  @override
  Future<XFile> stopVideoRecording(int cameraId) async => XFile(
    (await channel.invokeMethod<String>('stop', {'id': cameraId}))!,
    mimeType: 'video/mp4',
  );
  @override
  Future<void> setDescriptionWhileRecording(CameraDescription description) =>
      channel.invokeMethod<void>('switch', {'name': description.name});
  @override
  Widget buildPreview(int cameraId) => Texture(textureId: cameraId);
  @override
  Future<void> dispose(int cameraId) =>
      channel.invokeMethod<void>('dispose', {'id': cameraId});
}
