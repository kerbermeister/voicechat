import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/screen_quality.dart';

void main() {
  test('Low ограничивает экран без crop/upscale и сохраняет portrait', () {
    expect(ScreenQuality.low.scale(3840, 2160), 3);
    expect(ScreenQuality.low.scale(720, 1280), closeTo(1280 / 720, .001));
    expect(ScreenQuality.low.scale(640, 360), 1);
    expect(ScreenQuality.auto.scale(3840, 2160), 2);
    expect(ScreenQuality.low.bitrate, lessThan(ScreenQuality.auto.bitrate));
    expect(ScreenQuality.low.fps, 8);
  });
}
