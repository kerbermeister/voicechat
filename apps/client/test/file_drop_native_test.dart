import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/file_drop_native.dart';
import 'package:voicechat_probe/picked_file.dart';

void main() {
  const channel = MethodChannel('voicechat/file-drop');
  const codec = StandardMethodCodec();
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<dynamic> event(String name, dynamic args) async {
    final reply = Completer<dynamic>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(MethodCall(name, args)),
          (data) =>
              reply.complete(data == null ? null : codec.decodeEnvelope(data)),
        );
    return reply.future;
  }

  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  Widget app(bool enabled, void Function(List<PickedFile>) drop) => MaterialApp(
    theme: ThemeData(platform: TargetPlatform.macOS),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 200,
          height: 100,
          child: FileDrop(
            enabled: enabled,
            onDrop: drop,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    ),
  );
  Map<String, dynamic> payload(double x) => {
    'x': x,
    'y': 30.0,
    'files': [
      {
        'uri': 'opaque-id',
        'name': 'CLIP.MP4',
        'mime': 'application/octet-stream',
        'size': 100,
      },
    ],
  };
  testWidgets(
    'native drop accepts only enabled chat bounds and normalizes MIME',
    (tester) async {
      final received = <PickedFile>[];
      await tester.pumpWidget(app(true, received.addAll));
      await tester.pump();
      expect(calls.last.arguments, {
        'x': 0.0,
        'y': 0.0,
        'width': 200.0,
        'height': 100.0,
      });
      expect(await event('drop', payload(250)), false);
      expect(received, isEmpty);
      expect(await event('drop', payload(30)), true);
      expect(received.single.mime, 'video/mp4');
      await tester.pumpWidget(app(false, received.addAll));
      await tester.pump();
      expect(calls.last.arguments, isNull);
      expect(await event('drop', payload(30)), false);
      expect(received, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls.last.method, 'target');
      expect(calls.last.arguments, isNull);
    },
  );
  testWidgets('hover clears on exit and dialogs reject drops', (tester) async {
    await tester.pumpWidget(app(true, (_) => fail('Unexpected drop')));
    await event('hover', true);
    await tester.pump();
    expect(
      find.text('Отпустите файлы, чтобы прикрепить к чату'),
      findsOneWidget,
    );
    await event('hover', false);
    await tester.pump();
    expect(find.text('Отпустите файлы, чтобы прикрепить к чату'), findsNothing);
    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(FileDrop)),
        builder: (_) => const AlertDialog(title: Text('Modal')),
      ),
    );
    await tester.pumpAndSettle();
    expect(await event('drop', payload(30)), false);
    expect(calls.last.arguments, isNull);
  });
}
