import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/p2p/protocol.dart';

void main() {
  const json = {
    'p2p_file_max_bytes': 5000000000,
    'p2p_file_max_count': 10,
    'p2p_max_recipients': 4,
  };
  test('speed is per peer, ignores repeated ACKs and decays to zero', () {
    final a = P2pSpeed(), b = P2pSpeed();
    a.record(3000000, 1000);
    a.record(3000000, 1500);
    b.record(600000, 1000);
    expect(a.perSecond(2000), 1000000);
    expect(b.perSecond(2000), 200000);
    expect(a.perSecond(4000), 0);
    expect(() => a.record(1, 5000), throwsRangeError);
  });
  test(
    'policy fails closed for missing partial or invalid fields; legacy absent is unavailable',
    () {
      expect(P2pPolicy.parse({}), isNull);
      final policy = P2pPolicy.parse(json)!;
      const file = P2pFile('a', 'application/octet-stream', 5000000000, '');
      policy.validate(List.filled(10, file), 4);
      expect(
        () => policy.validate(List.filled(11, file), 4),
        throwsFormatException,
      );
      expect(() => policy.validate([file], 5), throwsFormatException);
      expect(
        () => policy.validate([const P2pFile('a', 'a', 5000000001, '')], 1),
        throwsFormatException,
      );
      for (final key in json.keys) {
        for (final value in [
          null,
          true,
          0,
          -1,
          1.5,
          '4',
          double.nan,
          100000000001,
        ]) {
          expect(
            () => P2pPolicy.parse({...json, key: value}),
            throwsFormatException,
          );
        }
      }
      expect(
        () => P2pPolicy.parse({'p2p_max_recipients': 4}),
        throwsFormatException,
      );
      P2pPolicy.parse({...json, 'p2p_max_recipients': 6})!.validate([file], 6);
    },
  );
  test('progress truncates safely and represents empty files truthfully', () {
    expect(p2pPercent(1871000000, 5000000000), '37,42%');
    expect(p2pPercent(4999999999, 5000000000), '99,99%');
    expect(p2pPercent(5000000000, 5000000000), '100,00%');
    expect(p2pPercent(99999999999, 100000000000), '99,99%');
    expect(p2pPercent(0, 0), '0,00%');
    expect(p2pPercent(0, 0, verified: true), '100,00%');
    expect(() => p2pPercent(2, 1), throwsRangeError);
  });
  test(
    'binary framing preserves offsets beyond 4 GiB and rejects malformed input',
    () {
      final payload = Uint8List.fromList([1, 2, 3]);
      for (final offset in [0, 2147483648, 4294967296, 99999999999]) {
        final frame = p2pFrame(3, offset, payload);
        final parsed = parseP2pFrame(frame);
        expect(parsed.file, 3);
        expect(parsed.offset, offset);
        expect(parsed.bytes, payload);
        frame[15] = 4;
        expect(() => parseP2pFrame(frame), throwsFormatException);
      }
      expect(() => parseP2pFrame(Uint8List(16)), throwsFormatException);
      expect(() => parseP2pFrame(Uint8List(16385)), throwsFormatException);
    },
  );
  test(
    'route uses selected pair and remote relay too; unknown never becomes direct',
    () {
      final stats = <Map<String, dynamic>>[
        {'id': 't', 'type': 'transport', 'selectedCandidatePairId': 'p'},
        {
          'id': 'p',
          'type': 'candidate-pair',
          'localCandidateId': 'l',
          'remoteCandidateId': 'r',
        },
        {'id': 'l', 'type': 'local-candidate', 'candidateType': 'host'},
        {'id': 'r', 'type': 'remote-candidate', 'candidateType': 'relay'},
      ];
      expect(p2pRouteFromStats(stats), P2pRoute.relay);
      stats.last['candidateType'] = 'srflx';
      expect(p2pRouteFromStats(stats), P2pRoute.direct);
      stats.removeLast();
      expect(p2pRouteFromStats(stats), P2pRoute.unknown);
    },
  );
  test('manifest bounded and streaming SHA-256 matches known empty digest', () {
    final hash = P2pHash().finish();
    expect(
      hash,
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    final data = {
      'name': '../a',
      'mime': 'text/plain',
      'size': 0,
      'sha256': hash,
    };
    expect(parseP2pFiles([data]).single.saveName, '.._a');
    for (final change in [
      {'size': -1},
      {'size': true},
      {'sha256': 'wrong'},
      {'name': 'a\n'},
      {'mime': 'text/\n'},
    ]) {
      expect(
        () => parseP2pFiles([
          {...data, ...change},
        ]),
        throwsFormatException,
      );
    }
    expect(() => parseP2pFiles(List.filled(101, data)), throwsFormatException);
  });
}
