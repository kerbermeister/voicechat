import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:voicechat_probe/lab_p2p_cross.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native macOS and Chrome exchange ten files in both directions', (
    tester,
  ) async {
    final base = Uri.parse(const String.fromEnvironment('P2P_CROSS_URL'));
    if (base.host != '127.0.0.1') {
      throw StateError('Disposable local fixture required');
    }
    await runP2pCross(base, 0, 'native');
    await runP2pCross(base, 1, 'native');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
