import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/matrix_probe.dart';

class TestRoom implements Room {
  @override
  final bool encrypted;
  final String? result;
  bool sent = false;
  TestRoom(this.encrypted, this.result);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #sendTextEvent) {
      expect(invocation.namedArguments[#parseCommands], false);
      sent = true;
      return Future<String?>.value(result);
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  test(
    'Only confirmed encrypted sends succeed; slash text stays text',
    () async {
      final plaintext = TestRoom(false, 'event');
      await expectLater(
        MatrixProbe.sendText(plaintext, 'hello'),
        throwsStateError,
      );
      expect(plaintext.sent, false);
      await expectLater(
        MatrixProbe.sendText(TestRoom(true, null), 'hello'),
        throwsStateError,
      );
      expect(
        await MatrixProbe.sendText(TestRoom(true, 'event'), '/hello'),
        'event',
      );
    },
  );
}
