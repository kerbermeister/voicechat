import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:voicechat_probe/call_stream_sync.dart';

void main() {
  test(
    'groups only one participant while retaining tracks and transport bytes',
    () {
      for (final newline in ['\r\n', '\n']) {
        final lines = [
          'v=0',
          'a=group:BUNDLE 0 1 2',
          'a=msid-semantic: WMS *',
          'm=audio 9 UDP/TLS/RTP/SAVPF 111',
          'a=fingerprint:sha-256 AB:CD:EF',
          'a=ice-ufrag:keep-ufrag',
          'a=ice-pwd:synthetic-test-password',
          'a=msid:PA_alice|TR_audio TR_audio',
          'a=ssrc:123 msid:PA_alice|TR_audio TR_audio',
          'a=rtpmap:111 opus/48000/2',
          'm=video 9 UDP/TLS/RTP/SAVPF 96 97',
          'a=msid:PA_alice|TR_video TR_video',
          'a=ssrc:456 msid:PA_alice|TR_video TR_video',
          'a=ssrc:789 msid:PA_alice|TR_video TR_video',
          'a=ssrc-group:FID 456 789',
          'a=fmtp:97 apt=96',
          'a=msid:PA_bob|TR_other TR_other',
          'a=extmap:7 urn:ietf:params:rtp-hdrext:encrypt urn:example:test',
          '',
        ];
        final before = lines.join(newline);
        final after = synchronizeCallStreams(
          rtc.RTCSessionDescription(before, 'offer'),
        );
        final expected = before
            .replaceAll('PA_alice|TR_audio ', 'PA_alice|voicechat-call ')
            .replaceAll('PA_alice|TR_video ', 'PA_alice|voicechat-call ')
            .replaceAll('PA_bob|TR_other ', 'PA_bob|voicechat-call ');
        expect(after.sdp, expected);
        expect(after.type, 'offer');
        expect(synchronizeCallStreams(after).sdp, after.sdp);
      }
    },
  );

  test(
    'updates explicit WMS list consistently with media and RTX associations',
    () {
      const before =
          'a=msid-semantic: WMS PA_a|TR_audio PA_a|TR_video other\r\n'
          'a=msid:PA_a|TR_audio TR_audio\r\n'
          'a=msid:PA_a|TR_video TR_video\r\n';
      expect(
        synchronizeCallStreams(rtc.RTCSessionDescription(before, 'offer')).sdp,
        'a=msid-semantic: WMS PA_a|voicechat-call other\r\n'
        'a=msid:PA_a|voicechat-call TR_audio\r\n'
        'a=msid:PA_a|voicechat-call TR_video\r\n',
      );
    },
  );

  test(
    'does not alter answers, unknown stream IDs or ambiguous track identities',
    () {
      for (final input in [
        rtc.RTCSessionDescription(null, 'offer'),
        rtc.RTCSessionDescription(
          'a=msid:PA_a|TR_audio TR_audio\r\n',
          'answer',
        ),
        rtc.RTCSessionDescription(
          'a=msid:PA_a|TR_audio different-track\r\n'
              'a=msid:PA_a|TR_audio TR_different\r\n'
              'a=msid:PA_a|already-shared TR_video\r\n'
              'a=msid:ordinary-stream TR_video\r\n'
              'a=msid:PA_a|TR_audio TR_audio extra\r\n',
          'offer',
        ),
      ]) {
        expect(synchronizeCallStreams(input), same(input));
      }
    },
  );

  test('leaves every association of a conflicting track unchanged', () {
    const before =
        'a=msid:PA_a|TR_audio TR_different\r\n'
        'a=ssrc:123 msid:PA_a|TR_audio TR_audio\r\n';
    final input = rtc.RTCSessionDescription(before, 'offer');
    expect(synchronizeCallStreams(input), same(input));
  });
}
