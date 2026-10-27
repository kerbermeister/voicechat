import 'dart:typed_data';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/voice_recording.dart';

class AudioFixtureClient implements mx.Client {
  @override
  String get userID => '@fixture:local';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Disposable in-memory audio only: no microphone, server, vault or user profile.
class AudioFixtureEvent extends mx.Event {
  final Uint8List bytes;
  int loads = 0;
  bool failDownload = false;
  AudioFixtureEvent(mx.Room room, String id, {int milliseconds = 1500})
    : bytes = voiceWav(Uint8List(milliseconds * 32)),
      super(
        room: room,
        eventId: id,
        type: mx.EventTypes.Message,
        senderId: '@fixture:local',
        originServerTs: DateTime(2026),
        content: {
          'msgtype': mx.MessageTypes.Audio,
          'body': '$id.wav',
          'info': {
            'size': milliseconds * 32 + 44,
            'duration': milliseconds,
            'mimetype': 'audio/wav',
          },
          'dev.voicechat.waveform': List.filled(32, 96),
        },
      );
  @override
  bool get isAttachmentEncrypted => true;
  @override
  Future<mx.MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    bool skipScanner = false,
    void Function(int)? onDownloadProgress,
  }) async {
    loads++;
    if (failDownload) throw StateError('Temporary fixture network failure');
    return mx.MatrixFile(
      bytes: bytes,
      name: 'voice.wav',
      mimeType: 'audio/wav',
    );
  }
}
