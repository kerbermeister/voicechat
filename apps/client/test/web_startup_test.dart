@TestOn('vm')
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('web startup handles slow downloads and failures', () async {
    final result = await Process.run('node', [
      '--test',
      'test/web_startup.cjs',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
}
