class MediaPolicy {
  final int photoMaxCount;
  final double photoScale;
  final int photoJpegQuality;
  final int photoMaxBytes;
  final int photoMaxPixels;
  final int textMaxLength;
  final int voiceMaxSeconds;
  final int videoNoteMaxSeconds;
  final int videoMaxBytes;
  final int fileMaxBytes;
  final int fileMaxCount;
  const MediaPolicy({
    this.photoMaxCount = 24,
    this.photoScale = .5,
    this.photoJpegQuality = 85,
    this.photoMaxBytes = 10485760,
    this.photoMaxPixels = 24000000,
    this.textMaxLength = 16000,
    this.voiceMaxSeconds = 180,
    this.videoNoteMaxSeconds = 60,
    this.videoMaxBytes = 314572800,
    this.fileMaxBytes = 314572800,
    this.fileMaxCount = 5,
  });

  factory MediaPolicy.fromJson(Map<String, dynamic> data) {
    if (data['version'] is! int || data['version'] != 1) {
      throw const FormatException('Unsupported policy');
    }
    int limit(String key, int high) {
      final value = data[key];
      if (value is! int || value < 1 || value > high) {
        throw FormatException('Invalid $key');
      }
      return value;
    }

    final scale = data['photo_scale'];
    if (scale is! num || !scale.isFinite || scale < .05 || scale > 1) {
      throw const FormatException('Invalid photo scale');
    }
    return MediaPolicy(
      photoMaxCount: limit('photo_max_count', 64),
      photoScale: scale.toDouble(),
      photoJpegQuality: limit('photo_jpeg_quality', 100),
      photoMaxBytes: limit('photo_max_bytes', 10485760),
      photoMaxPixels: limit('photo_max_pixels', 24000000),
      textMaxLength: limit('text_max_length', 16000),
      voiceMaxSeconds: limit('voice_max_seconds', 180),
      videoNoteMaxSeconds: limit('video_note_max_seconds', 600),
      videoMaxBytes: limit('video_max_bytes', 314572800),
      fileMaxBytes: limit('file_max_bytes', 314572800),
      fileMaxCount: data.containsKey('file_max_count')
          ? limit('file_max_count', 20)
          : 5,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'photo_max_count': photoMaxCount,
    'photo_scale': photoScale,
    'photo_jpeg_quality': photoJpegQuality,
    'photo_max_bytes': photoMaxBytes,
    'photo_max_pixels': photoMaxPixels,
    'text_max_length': textMaxLength,
    'voice_max_seconds': voiceMaxSeconds,
    'video_note_max_seconds': videoNoteMaxSeconds,
    'video_max_bytes': videoMaxBytes,
    'file_max_bytes': fileMaxBytes,
    'file_max_count': fileMaxCount,
  };
}
