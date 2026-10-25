import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/macos_update_dialog.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final methods = <String>[];
  Future<void> emit(Map<String, dynamic> state) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      MacOSUpdateDialog.channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('state', state)),
      (_) {},
    );
  }

  setUp(() {
    methods.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      MacOSUpdateDialog.channel,
      (call) async {
        methods.add(call.method);
        return call.method == 'info'
            ? {'version': '1.1.0', 'build': '2'}
            : null;
      },
    );
  });
  tearDown(
    () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
      MacOSUpdateDialog.channel,
      null,
    ),
  );

  testWidgets('opening is local; check and download require explicit actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MacOSUpdateDialog(prepareInstall: () async => null),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(methods, ['info']);
    await tester.tap(find.text('Проверить обновления'));
    await tester.pumpAndSettle();
    expect(methods, ['info', 'check']);
    await emit({
      'phase': 'available',
      'version': '1.2.0',
      'build': '3',
      'size': 1024,
      'minimumOS': '12.0',
      'notes': 'Исправления',
    });
    await tester.pumpAndSettle();
    expect(methods, isNot(contains('download')));
    await tester.tap(find.text('Скачать и установить'));
    await tester.pumpAndSettle();
    expect(methods.last, 'download');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'active media prevents installation and explains how to continue',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MacOSUpdateDialog(
              prepareInstall: () async => 'Завершите звонок.',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await emit({
        'phase': 'ready',
        'version': '1.2.0',
        'build': '3',
        'size': 1024,
        'minimumOS': '12.0',
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Продолжить установку'));
      await tester.pumpAndSettle();
      expect(methods, isNot(contains('install')));
      expect(find.text('Завершите звонок.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
