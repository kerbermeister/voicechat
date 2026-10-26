import 'package:flutter/material.dart';
import 'video_note.dart' show VideoNoteResult;

Future<VideoNoteResult?> recordWebVideoNote(
  BuildContext context,
  int maxSeconds, {
  ValueNotifier<bool>? held,
  ValueNotifier<bool>? cancelled,
  void Function(bool)? onRecording,
}) => throw UnsupportedError('Browser recording only');
