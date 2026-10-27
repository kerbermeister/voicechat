import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:voicechat_probe/active_capture.dart';
import 'package:voicechat_probe/video_note.dart';

class NoteCamera extends CameraPlatform {
  final initialized = StreamController<CameraInitializedEvent>.broadcast();
  final errors = StreamController<CameraErrorEvent>.broadcast();
  int starts = 0, stops = 0, creations = 0;
  Completer<void>? starting;
  @override
  Future<List<CameraDescription>> availableCameras() async => [
    const CameraDescription(
      name: 'front',
      lensDirection: CameraLensDirection.front,
      sensorOrientation: 0,
    ),
  ];
  @override
  Future<int> createCameraWithSettings(
    CameraDescription description,
    MediaSettings settings,
  ) async {
    creations++;
    return 1;
  }

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();
  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      initialized.stream;
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => errors.stream;
  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    initialized.add(
      const CameraInitializedEvent(
        1,
        320,
        320,
        ExposureMode.auto,
        false,
        FocusMode.auto,
        false,
      ),
    );
  }

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async {
    starts++;
    await starting?.future;
  }

  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    stops++;
    return XFile.fromData(
      Uint8List(64),
      name: 'note.webm',
      mimeType: 'video/webm',
    );
  }

  @override
  Widget buildPreview(int cameraId) => const ColoredBox(color: Colors.black);
  @override
  Future<void> dispose(int cameraId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('voicechat/save'),
        (_) async => Directory.systemTemp.path,
      );
  late NoteCamera camera;
  setUp(() {
    camera = NoteCamera();
    final old = CameraPlatform.instance;
    CameraPlatform.instance = camera;
    addTearDown(() async {
      CameraPlatform.instance = old;
      await camera.initialized.close();
    });
  });
  for (final scenario in [
    'tap',
    'release',
    'cancel',
    'swipe',
    'interrupted',
    'cancel during start',
  ]) {
    testWidgets('Video note $scenario starts once and completes safely', (
      tester,
    ) async {
      final held = scenario == 'tap' ? null : ValueNotifier(true);
      final cancelled = ValueNotifier(false);
      VideoNoteResult? result;
      var completed = false;
      if (scenario == 'cancel during start') camera.starting = Completer();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await recordVideoNote(
                    context,
                    60,
                    held: held,
                    cancelled: cancelled,
                  );
                  completed = true;
                },
                child: const Text('Кружок'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Кружок'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      expect(camera.starts, 1);
      expect(completed, false);
      if (scenario == 'tap') {
        await tester.tap(find.text('Отправить'));
      } else if (scenario == 'cancel' || scenario == 'cancel during start') {
        await tester.tap(find.text('Отмена'));
        camera.starting?.complete();
      } else if (scenario == 'interrupted') {
        unawaited(stopActiveCapture());
      } else {
        cancelled.value = scenario == 'swipe';
        held!.value = false;
      }
      for (var i = 0; i < 100 && !completed; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      expect(completed, true);
      expect(camera.stops, 1);
      if (['cancel', 'swipe', 'cancel during start'].contains(scenario)) {
        expect(result, isNull);
      } else {
        expect(result, isNotNull);
        expect(result!.interrupted, scenario == 'interrupted');
      }
      await tester.pumpWidget(const SizedBox());
      held?.dispose();
      cancelled.dispose();
    });
  }
}
