import 'test_fonts.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/main.dart';
import 'package:voicechat_probe/registration_screen.dart';
import 'package:voicechat_probe/theme.dart';
import 'registration_screen_test.dart' show RegistrationClient, send;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Capture redesigned authentication with fictional data', (
    tester,
  ) async {
    for (final (name, file) in [
      ('Roboto', 'Roboto-Regular.ttf'),
      ('MaterialIcons', 'MaterialIcons-Regular.otf'),
    ]) {
      final font = FontLoader(name)
        ..addFont(
          Future.value(
            ByteData.sublistView(materialFontFile(file).readAsBytesSync()),
          ),
        );
      await font.load();
    }
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const key = ValueKey('auth-capture');
    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image = await tester
            .renderObject<RenderRepaintBoundary>(find.byKey(key))
            .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '../../docs/design/halo-auth/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    for (final (surface, size) in [
      ('desktop', const Size(1440, 1000)),
      ('mobile', const Size(390, 844)),
    ]) {
      tester.view.physicalSize = size;
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        const RepaintBoundary(key: key, child: VoiceChatApp()),
      );
      await capture('$surface-login');
      for (final reset in [false, true]) {
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppPalette.halo.theme,
              locale: const Locale('ru'),
              supportedLocales: const [Locale('ru')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: RegistrationScreen(
                key: ValueKey(reset),
                resetPassword: reset,
                openClient: (_) async => RegistrationClient(),
              ),
            ),
          ),
        );
        await capture('$surface-${reset ? 'reset' : 'register'}');
        if (!reset) {
          // Fill fields with scroll so the same test runs on mobile viewports.
          for (final (label, value) in [
            ('Имя пользователя · латиницей', 'anton'),
            ('Электронная почта', 'anton@example.test'),
            ('Пароль аккаунта · от 12 символов', 'fictional password'),
            ('Повторите пароль', 'fictional password'),
          ]) {
            final input = find.widgetWithText(TextField, label);
            await tester.ensureVisible(input);
            await tester.enterText(input, value);
          }
          await send(tester);
          await tester.drag(
            find.byType(SingleChildScrollView).first,
            const Offset(0, 2000),
          );
          await capture('$surface-email');
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
  }, skip: !const bool.fromEnvironment('AUTH_CAPTURE'));
}
