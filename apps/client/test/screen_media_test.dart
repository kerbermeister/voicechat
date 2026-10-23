import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:voicechat_probe/screen_controller.dart';

void main() {
  test(
    'Audio с поддельным screen source, camera, plaintext и AV1 не подписываются',
    () {
      expect(
        allowsScreenMedia(
          lk.EncryptionType.kGcm,
          lk.TrackSource.screenShareVideo,
          lk.TrackType.VIDEO,
          'video/VP8',
        ),
        isTrue,
      );
      expect(
        allowsScreenMedia(
          lk.EncryptionType.kGcm,
          lk.TrackSource.screenShareVideo,
          lk.TrackType.AUDIO,
          'audio/opus',
        ),
        isFalse,
      );
      expect(
        allowsScreenMedia(
          lk.EncryptionType.kGcm,
          lk.TrackSource.camera,
          lk.TrackType.VIDEO,
          'video/VP8',
        ),
        isFalse,
      );
      expect(
        allowsScreenMedia(
          lk.EncryptionType.kNone,
          lk.TrackSource.screenShareVideo,
          lk.TrackType.VIDEO,
          'video/VP8',
        ),
        isFalse,
      );
      expect(
        allowsScreenMedia(
          lk.EncryptionType.kGcm,
          lk.TrackSource.screenShareAudio,
          lk.TrackType.AUDIO,
          'audio/opus',
        ),
        isFalse,
      );
      expect(
        allowsScreenMedia(
          lk.EncryptionType.kGcm,
          lk.TrackSource.screenShareVideo,
          lk.TrackType.VIDEO,
          'video/AV1',
        ),
        isFalse,
      );
    },
  );
}
