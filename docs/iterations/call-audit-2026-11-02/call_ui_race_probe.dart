// Intended safety assertions for call controls and rapid lifecycle transitions.
// Production widgets/controllers with synthetic calls; no hardware or accounts.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/call_controller.dart';
import 'package:voicechat_probe/call_window.dart';

import '../../../apps/client/test/call_window_test.dart'
    show WindowCall, CallRoom, WindowDatabase;

class PendingControlCall extends WindowCall {
  PendingControlCall(super.room);
  final gate = Completer<void>();
  final operations = <String>[];
  bool pending = false;
  @override
  Future<void> camera(bool enabled) async {
    operations.add('camera:$enabled');
    cameraEnabled = enabled;
    if (!enabled && pending) await gate.future;
  }

  @override
  Future<void> mute(bool value) async {
    operations.add('mute:$value');
    if (pending) await gate.future;
    muted = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Event'),
          (_) async => null,
        );
  });
  for (final operation in ['camera', 'mute']) {
    testWidgets('Hangup remains enabled while $operation is waiting', (
      tester,
    ) async {
      final client = Client('qa-control', database: WindowDatabase());
      final call = PendingControlCall(CallRoom(client))..pending = true;
      final calls = CallController(
        client,
        'http://localhost:9',
        'ws://localhost:9',
        (_) {},
      )..active = call;
      await tester.pumpWidget(
        MaterialApp(
          home: CallWindow(calls: calls, audioOutput: () async {}),
        ),
      );
      await tester.pump();
      await tester.tap(
        find.byTooltip(
          operation == 'camera' ? 'Выключить камеру' : 'Выключить микрофон',
        ),
      );
      await tester.pump();
      final end = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Завершить'),
      );
      final endWasEnabled = end.onPressed != null;
      call.gate.complete();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      calls.active = null;
      await tester.runAsync(calls.close);
      await client.dispose();
      expect(
        endWasEnabled,
        true,
        reason: 'A stalled optional control must not block leaving a call',
      );
    });
  }
  testWidgets(
    'inactive resumed inactive must not enable camera in the final inactive state',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final client = Client('qa-lifecycle', database: WindowDatabase());
      final call = PendingControlCall(CallRoom(client))..pending = true;
      final calls = CallController(
        client,
        'http://localhost:9',
        'ws://localhost:9',
        (_) {},
      )..active = call;
      calls.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await tester.pump();
      expect(call.cameraEnabled, false);
      calls.didChangeAppLifecycleState(AppLifecycleState.resumed);
      calls.didChangeAppLifecycleState(AppLifecycleState.inactive);
      call.gate.complete();
      await tester.pump();
      await tester.pump();
      final enabledWhileInactive = call.cameraEnabled;
      calls.active = null;
      await tester.runAsync(calls.close);
      await client.dispose();
      expect(
        enabledWhileInactive,
        false,
        reason: 'Queued resume must respect a subsequent inactive transition',
      );
    },
  );
}
