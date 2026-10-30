import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/connection_diagnostics.dart';
import 'call_window_test.dart' show WindowCall, CallRoom, WindowDatabase;

void main() {
  test(
    'Diagnostic report omits peer, room, session and server identities',
    () async {
      final client = Client(
        'private-account-fixture',
        database: WindowDatabase(),
      );
      final call = WindowCall(CallRoom(client), video: false);
      final snapshot = await connectionDiagnostics(null, call);
      expect(snapshot['schema'], 1);
      expect((snapshot['call'] as Map)['duration_ms'], 42000);
      final text = jsonEncode(snapshot);
      for (final secret in [
        'private-account-fixture',
        call.chat.id,
        call.session,
        'access_token',
        'password',
      ]) {
        expect(text, isNot(contains(secret)));
      }
      call.isClosed = true;
      expect((await connectionDiagnostics(null, call))['call'], {
        'state': 'inactive',
      });
      expect((await connectionDiagnostics(null, null))['call'], {
        'state': 'inactive',
      });
      await client.dispose();
    },
  );
}
