import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/screen_binding.dart';
import 'package:voicechat_probe/user_action_error.dart';

void main() {
  test(
    'Выбрано доверенное устройство ответившей стороны, а не другое её устройство',
    () {
      expect(
        selectedScreenPeer('@peer:x', 'ANSWER', [
          (user: '@peer:x', device: 'OTHER'),
          (user: '@peer:x', device: 'ANSWER'),
        ]),
        {'user_id': '@peer:x', 'device_id': 'ANSWER'},
      );
    },
  );
  test('Чужой или отсутствующий party_id не становится экранным допуском', () {
    for (final party in <String?>[null, 'UNKNOWN', 'DEVICE']) {
      expect(
        () => selectedScreenPeer('@peer:x', party, [
          (user: '@other:x', device: 'DEVICE'),
        ]),
        throwsA(isA<UserActionError>()),
      );
    }
  });
}
