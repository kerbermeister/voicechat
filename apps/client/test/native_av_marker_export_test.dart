import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/native_av_marker_test.dart'
    show captureNativeMarkers;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('voicechat/test-marker-export');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Map<String, dynamic> chunk(int index) => {
    'time': index.toDouble(),
    'rate': 48000,
    'frames': 1,
    'pcm': Uint8List.fromList([index & 255, 0, 128, 255]),
  };

  test('preserves legacy native PCM and metadata byte for byte', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'result');
      expect(call.arguments, {'includeAudio': false});
      return {
        'audio': [chunk(7)],
        'video': [
          [1, 2.0],
        ],
      };
    });
    final result = await captureNativeMarkers(channel);
    expect(base64Decode(result['audio'][0]['pcm']), chunk(7)['pcm']);
    expect(result['video'], [
      [1, 2.0],
    ]);
  });

  test(
    'reads both snapshot streams in bounded pages without losing samples',
    () async {
      final requests = <Map>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'result') {
          return {
            'audio': [],
            'audio_count': 129,
            'control_audio': [],
            'control_audio_count': 1,
          };
        }
        expect(call.method, 'audioChunks');
        final arguments = call.arguments as Map;
        requests.add(arguments);
        final offset = arguments['offset'] as int;
        return [for (var i = 0; i < arguments['limit']; i++) chunk(offset + i)];
      });
      final result = await captureNativeMarkers(channel);
      expect(requests, [
        {'control': false, 'offset': 0, 'limit': 128},
        {'control': false, 'offset': 128, 'limit': 1},
        {'control': true, 'offset': 0, 'limit': 1},
      ]);
      expect(result['audio'], hasLength(129));
      for (var i = 0; i < 129; i++) {
        expect(base64Decode(result['audio'][i]['pcm']), chunk(i)['pcm']);
        expect(result['audio'][i]['time'], i.toDouble());
      }
      expect(result['control_audio'], hasLength(1));
      expect(result.containsKey('audio_count'), isFalse);
      expect(result.containsKey('control_audio_count'), isFalse);
    },
  );

  test('rejects invalid snapshot bounds and incomplete native pages', () async {
    for (final count in [-1, 1, 14001]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'result') return {'audio': [], 'audio_count': count};
        expect(count, 1);
        return [];
      });
      await expectLater(captureNativeMarkers(channel), throwsStateError);
    }
  });

  test(
    'rejects missing required streams instead of losing a recording',
    () async {
      for (final snapshot in [
        <String, dynamic>{},
        {'audio': [], 'audio_count': 0, 'control_audio_count': 1},
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async => snapshot);
        await expectLater(captureNativeMarkers(channel), throwsStateError);
      }
    },
  );
}
