import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:shared_preferences/shared_preferences.dart';
import 'call_controller.dart';

class AppSounds {
  final mx.Client client;
  final effect = AudioPlayer();
  final ringing = AudioPlayer();
  final opened = DateTime.now();
  final seen = <String>{};
  StreamSubscription<mx.Event>? events;
  bool enabled = true;
  bool blocked = false;
  bool _closed = false;
  String? _ring;
  Future<void> _ringWrites = Future.value();
  AppSounds(this.client);
  Future<void> open() async {
    await effect.setAudioContext(
      AudioContext(
        android: const AudioContextAndroid(audioFocus: AndroidAudioFocus.none),
      ),
    );
    await ringing.setAudioContext(
      AudioContext(
        android: const AudioContextAndroid(
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          usageType: AndroidUsageType.notificationRingtone,
        ),
      ),
    );
    enabled =
        (await SharedPreferences.getInstance()).getBool('soundsEnabled') ??
        true;
    await ringing.setReleaseMode(ReleaseMode.loop);
    events = client.onTimelineEvent.stream.listen((event) {
      if (event.type != mx.EventTypes.Message ||
          event.redacted ||
          event.senderId == client.userID ||
          event.originServerTs.isBefore(opened) ||
          event.relationshipType == mx.RelationshipTypes.edit ||
          [
            'dev.voicechat.call',
            'dev.voicechat.call_summary',
          ].contains(event.messageType) ||
          !seen.add(event.eventId)) {
        return;
      }
      if (seen.length > 2000) seen.remove(seen.first);
      if (event.room.pushRuleState == mx.PushRuleState.dontNotify) return;
      unawaited(_play(effect, 'received'));
    });
  }

  Future<void> _play(AudioPlayer player, String asset) async {
    if (!enabled || _closed) return;
    try {
      await player.play(AssetSource('sounds/$asset.wav'));
      blocked = false;
    } catch (_) {
      blocked = true;
    }
  }

  void sent() => unawaited(_play(effect, 'sent'));
  void updateCall(CallController calls) {
    final incoming =
        calls.directInvitations.isNotEmpty || calls.invitations.isNotEmpty;
    final active = calls.active;
    final outgoing =
        !incoming &&
        (calls.starting ||
            active != null &&
                !active.isClosed &&
                active.duration == Duration.zero);
    final next = !enabled
        ? null
        : incoming
        ? 'ringtone'
        : outgoing
        ? 'ringback'
        : null;
    if (_ring == next) return;
    _ring = next;
    _ringWrites = _ringWrites.catchError((Object _) {}).then((_) async {
      if (_closed) return;
      await ringing.stop();
      if (_ring != null) await _play(ringing, _ring!);
    });
  }

  Future<void> setEnabled(bool value) async {
    await (await SharedPreferences.getInstance()).setBool(
      'soundsEnabled',
      value,
    );
    enabled = value;
    if (!value) {
      _ring = null;
      await effect.stop();
      await ringing.stop();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await events?.cancel();
    await _ringWrites;
    await effect.dispose();
    await ringing.dispose();
  }
}
