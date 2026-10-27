import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/file_io_native.dart';
import 'package:voicechat_probe/file_save_result.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  var cancelled = false;
  setUp(() {
    calls.clear();
    cancelled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('voicechat/save'), (
          call,
        ) async {
          calls.add(call);
          return call.method == 'begin' ? 'selection' : null;
        });
  });
  Future<FileSaveResult> save(int size, List<Uint8List> chunks) =>
      saveStreamFile(
        'same.bin',
        'application/octet-stream',
        size,
        (_, __) => Stream.fromIterable(chunks),
        (_) {},
        () => cancelled,
      );
  test(
    'export commits only an exact completed stream, including empty file',
    () async {
      expect(await save(4, [Uint8List(2), Uint8List(2)]), FileSaveResult.saved);
      expect(calls.last.arguments['success'], true);
      calls.clear();
      expect(await save(0, []), FileSaveResult.saved);
      expect(calls.map((c) => c.method), ['begin', 'finish']);
    },
  );
  test(
    'short read aborts staging instead of committing a damaged destination',
    () async {
      await expectLater(save(4, [Uint8List(2)]), throwsStateError);
      expect(calls.last.arguments['success'], false);
    },
  );
  test(
    'cancel before first block and empty cancel both abort staging',
    () async {
      cancelled = true;
      for (final size in [0, 4]) {
        await expectLater(
          save(size, size == 0 ? [] : [Uint8List(4)]),
          throwsStateError,
        );
        expect(calls.last.arguments['success'], false);
      }
      expect(calls.where((c) => c.method == 'write'), isEmpty);
    },
  );
}
