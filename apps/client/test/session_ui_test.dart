import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/main.dart';
import 'package:voicechat_probe/matrix_probe.dart';
import 'call_window_test.dart' show WindowDatabase;

void main() {
  testWidgets(
    'Login failure explains recovery without exposing exception types',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const VoiceChatApp());
      await tester.pumpAndSettle();
      final dynamic screen = tester.state(find.byType(ProbeScreen));
      await screen.run(
        () async => throw StateError('internal-sensitive-marker'),
      );
      await tester.pump();
      expect(
        find.text(
          'Не удалось выполнить действие. Проверьте подключение и данные входа, затем повторите попытку.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('StateError'), findsNothing);
      expect(find.textContaining('internal-sensitive-marker'), findsNothing);
    },
  );

  testWidgets(
    'Revoked session detaches chat before cleanup and retains local profile',
    (tester) async {
      // Avoid auto-restoring a fixture: install its cached session after first render.
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const VoiceChatApp());
      await tester.pumpAndSettle();
      final dynamic screen = tester.state(find.byType(ProbeScreen));
      final client = Client('revoked-qa', database: WindowDatabase());
      screen.probe = MatrixProbe(client);
      screen.linked = true;
      screen.savedAccount = true;
      final profile = screen.profile.text;
      final closing = screen.lock(sessionEnded: true);
      expect(screen.probe, isNull);
      expect(screen.selected, isNull);
      expect(screen.calls, isNull);
      expect(screen.savedAccount, false);
      expect(screen.profile.text, profile);
      await tester.runAsync(() async => await closing);
      await tester.pumpAndSettle();
      expect(find.textContaining('доступ устройства отозван'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
