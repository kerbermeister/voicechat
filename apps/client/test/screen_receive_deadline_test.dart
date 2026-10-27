import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/screen_receive_deadline.dart';

void main() {
  testWidgets('Repeated unsuccessful key/track events cannot prolong waiting', (
    tester,
  ) async {
    var failures = 0;
    final deadline = ScreenReceiveDeadline(() => failures++);
    for (var second = 0; second < 20; second++) {
      deadline.start();
      expect(failures, 0);
      await tester.pump(const Duration(seconds: 1));
    }
    expect(failures, 1);
    deadline.start();
    await tester.pump(const Duration(seconds: 30));
    expect(failures, 1);
    deadline.reset();
  });
  testWidgets(
    'Receiving a picture or closing cancels; retry has a fresh deadline',
    (tester) async {
      var failures = 0;
      final deadline = ScreenReceiveDeadline(() => failures++);
      deadline.start();
      await tester.pump(const Duration(seconds: 19));
      deadline.reset();
      await tester.pump(const Duration(seconds: 30));
      expect(failures, 0);
      deadline.start();
      await tester.pump(const Duration(seconds: 20));
      expect(failures, 1);
      deadline.reset();
    },
  );
}
