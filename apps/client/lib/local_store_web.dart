import 'package:matrix/matrix.dart';

Future<MatrixSdkDatabase> openStore(String name, {bool laboratory = false}) {
  if (!laboratory) {
    throw UnsupportedError(
      'Web vault is not ready; persistent login is disabled',
    );
  }
  return MatrixSdkDatabase.init(name);
}

Future<void> eraseStore(String name) async {
  throw UnsupportedError('Web vault is not ready');
}
