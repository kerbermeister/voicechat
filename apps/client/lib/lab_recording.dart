// Platform compatibility check for disposable microphone data; never writes a file.
import 'dart:async';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';
import 'voice_recording.dart';

Future<void> checkRecording() async {
  final recorder = AudioRecorder();
  final player = AudioPlayer();
  final pcm = BytesBuilder(copy: false);
  final closed = Completer<void>();
  StreamSubscription<Uint8List>? subscription;
  try {
    if (!await recorder.hasPermission()) throw StateError('Microphone denied');
    final stream = await recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    subscription = stream.listen(
      pcm.add,
      onDone: closed.complete,
      onError: closed.completeError,
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    await recorder.stop();
    await closed.future.timeout(const Duration(seconds: 10));
    final bytes = pcm.takeBytes();
    if (bytes.length < 1600) {
      throw StateError('Recorder returned no usable PCM');
    }
    final completed = player.onPlayerComplete.first.timeout(
      const Duration(seconds: 10),
    );
    await player.play(BytesSource(voiceWav(bytes), mimeType: 'audio/wav'));
    await completed;
  } finally {
    await subscription?.cancel();
    await recorder.dispose();
    await player.dispose();
  }
}
