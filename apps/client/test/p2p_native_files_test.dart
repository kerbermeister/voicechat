import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/file_drop.dart';
import 'package:voicechat_probe/file_source_native.dart';

void main() {
  testWidgets(
    'Native drop selects only the visible enabled target; offsets above 4GB remain exact',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final drops = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FileDrop(
              enabled: true,
              onDrop: (files) => drops.addAll(files.map((f) => f.name)),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      Future<bool> drop(double x) async {
        final reply = await tester.runAsync(() async {
          final done = Completer<ByteData?>();
          tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            'voicechat/file-drop',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('drop', {
                'x': x,
                'y': 100.0,
                'files': [
                  {
                    'uri': 'opaque',
                    'name': 'large.bin',
                    'mime': 'application/octet-stream',
                    'size': 5000000000,
                  },
                ],
              }),
            ),
            done.complete,
          );
          return done.future;
        });
        return const StandardMethodCodec().decodeEnvelope(reply!) as bool;
      }

      expect(await drop(100), true);
      expect(drops, ['large.bin']);
      expect(await drop(5000), false);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('voicechat/files'), (
            call,
          ) async {
            expect(call.arguments['start'], 4999999999);
            expect(call.arguments['end'], 5000000000);
            return Uint8List(1);
          });
      final file = fileSource({
        'uri': 'opaque',
        'name': 'large.bin',
        'mime': 'application/octet-stream',
        'size': 5000000000,
      });
      expect(await file.read(4999999999, 5000000000), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
