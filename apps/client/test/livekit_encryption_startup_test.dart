// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/src/utils.dart';

void main() {
  test(
    'encryption startup gate preserves encoding quality and caller state',
    () {
      final requested = [
        rtc.RTCRtpEncoding(
          rid: 'q',
          maxBitrate: 120000,
          maxFramerate: 15,
          scaleResolutionDownBy: 4,
        ),
        rtc.RTCRtpEncoding(
          rid: 'h',
          active: false,
          maxBitrate: 400000,
          maxFramerate: 30,
          scaleResolutionDownBy: 2,
        ),
        rtc.RTCRtpEncoding(
          rid: 'f',
          maxBitrate: 1500000,
          maxFramerate: 30,
          scalabilityMode: 'L1T3',
        ),
      ];
      final before = requested.map((encoding) => encoding.toMap()).toList();
      final gated = Utils.encodingsBeforeEncryption(requested, true)!;
      expect(gated.map((encoding) => encoding.active), everyElement(false));
      for (var index = 0; index < requested.length; index++) {
        final expected = {...before[index], 'active': false};
        expect(gated[index].toMap(), expected);
        expect(requested[index].toMap(), before[index]);
      }
      expect(
        identical(Utils.encodingsBeforeEncryption(requested, false), requested),
        isTrue,
      );
      expect(
        Utils.encodingsBeforeEncryption(null, true)!.single.active,
        isFalse,
      );
      expect(Utils.encodingsBeforeEncryption(null, false), isNull);
    },
  );
}
