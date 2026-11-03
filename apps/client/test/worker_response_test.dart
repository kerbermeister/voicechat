// ignore: implementation_imports
import 'package:dart_webrtc/src/worker_response.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Matched successful worker reply preserves its original payload', () {
    final data = {'msgId': 'request', 'type': 'setKey', 'msgType': 'response'};
    final response = WorkerResponse('request', data);
    response.ensureSuccess();
    expect(response.data, same(data));
    expect(response.msgId, 'request');
  });

  final invalid = <Object?>[
    null,
    false,
    'response',
    [],
    {'error': 'Private worker diagnostic'},
    {'error': null},
  ];
  for (var i = 0; i < invalid.length; i++) {
    test(
      'Malformed or rejected worker reply $i fails without exposing data',
      () {
        final response = WorkerResponse('request', invalid[i]);
        expect(
          response.ensureSuccess,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'safe diagnostic',
              'Frame encryption worker rejected the request',
            ),
          ),
        );
      },
    );
  }
}
