import 'dart:math' as math;

/// Верхние пределы экрана; пропорции не меняются, маленький источник не увеличиваем.
enum ScreenQuality {
  auto('Авто', 1920, 1080, 15, 2500000),
  low('Низкое', 1280, 720, 8, 1000000);

  final String label;
  final int width, height, fps, bitrate;
  const ScreenQuality(
    this.label,
    this.width,
    this.height,
    this.fps,
    this.bitrate,
  );
  double scale(num sourceWidth, num sourceHeight) => math
      .max(1, math.max(sourceWidth / width, sourceHeight / height))
      .toDouble();
}
