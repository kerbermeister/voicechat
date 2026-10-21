import 'package:matrix/matrix.dart';
import 'call_quality.dart';

abstract interface class VoiceCall {
  Room get chat;
  String get session;
  String get connection;
  bool get muted;
  bool get isClosed;
  List<String> get participants;
  Duration get duration;
  bool get video;
  bool get cameraEnabled;
  VideoQuality get videoQuality;
  CallQuality get quality;
  Future<void> camera(bool enabled);
  Future<void> switchCamera();
  Future<void> setVideoQuality(VideoQuality value);
  Future<void> mute(bool muted);
  Future<void> close();
}
