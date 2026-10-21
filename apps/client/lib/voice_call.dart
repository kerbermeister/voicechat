import 'package:matrix/matrix.dart';

abstract interface class VoiceCall {
  Room get chat;
  String get session;
  String get connection;
  bool get muted;
  bool get isClosed;
  List<String> get participants;
  Duration get duration;
  Future<void> mute(bool muted);
  Future<void> close();
}
