import 'dart:async';
import 'package:flutter/foundation.dart';
import 'browser_audio.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:shared_preferences/shared_preferences.dart';
import 'call_controller.dart';
import 'direct_call.dart';
import 'voice_call.dart';

class AppSounds {
  final mx.Client client;
  final AudioPlayer effect;
  final AudioPlayer ringing;
  final opened = DateTime.now();
  final seen = <String>{};
  StreamSubscription<mx.Event>? events;
  bool enabled = true;
  bool blocked = false;
  bool _closed = false;
  String? _ring;
  int _ringRevision = 0;
  VoiceCall? _observedCall;
  Future<void> _ringWrites = Future.value();
  final Future<void> Function(String room, String event)? onReceived;
  final Future<bool> Function()? systemIncomingRinging;
  AppSounds(
    this.client, {
    this.onReceived,
    this.systemIncomingRinging,
    AudioPlayer? effect,
    AudioPlayer? ringing,
  }) : effect = effect ?? AudioPlayer(),
       ringing = ringing ?? AudioPlayer();
  Future<void> open() async {
    if (kIsWeb) prepareBrowserAudio();
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
      unawaited(onReceived?.call(event.room.id, event.eventId));
      unawaited(_play(effect, 'received'));
    });
  }

  Future<void> _play(AudioPlayer player, String asset) async {
    if (!enabled || _closed) return;
    try {
      if (player == ringing &&
          asset == 'ringtone' &&
          await systemIncomingRinging?.call() == true) {
        return; // The insistent Android notification already owns this ringtone.
      }
      if (kIsWeb) {
        blocked = !await playBrowserSound(
          player == ringing ? 'ring' : 'effect',
          asset,
          player == ringing,
        );
        return;
      }
      await player.play(AssetSource('sounds/$asset.wav'));
      blocked = false;
    } catch (_) {
      blocked = true;
    }
  }

  void sent() => unawaited(_play(effect, 'sent'));
  void deleted() => unawaited(_play(effect, 'deleted'));
  void updateCall(CallController calls) {
    final previous = _observedCall;
    if (previous != null && previous.isClosed) {
      _observedCall = null;
      unawaited(_play(effect, 'ended'));
    }
    if (calls.active?.isClosed == false) _observedCall = calls.active;
    final incoming =
        calls.directInvitations.any((call) => !call.isClosed) ||
        calls.invitations.isNotEmpty;
    final active = calls.active;
    final outgoing =
        !incoming &&
        ((calls.starting && (active == null || !active.isClosed)) ||
            active != null &&
                !active.isClosed &&
                (active is! DirectCall ||
                    active.call.direction == mx.CallDirection.kOutgoing) &&
                active.duration == Duration.zero &&
                !calls.devices.isAccepted(active));
    final next = !enabled
        ? null
        : incoming
        ? 'ringtone'
        : outgoing
        ? 'ringback'
        : null;
    _setRing(next);
  }

  Future<void> _stopRing() async {
    if (kIsWeb) stopBrowserSound('ring');
    try {
      await ringing.stop();
    } catch (_) {
      blocked = true;
    }
  }

  void _setRing(String? next) {
    if (_ring == next) return;
    _ring = next;
    final revision = ++_ringRevision;
    // Cancels AudioPlayer.desiredState even while an earlier play prepares.
    if (next == null) unawaited(_stopRing());
    _ringWrites = _ringWrites.catchError((Object _) {}).then((_) async {
      if (_closed || revision != _ringRevision) return;
      await _stopRing();
      if (_closed || revision != _ringRevision || next == null) return;
      await _play(ringing, next);
      if (_closed || revision != _ringRevision) await _stopRing();
    });
  }

  Future<void> setEnabled(bool value) async {
    await (await SharedPreferences.getInstance()).setBool(
      'soundsEnabled',
      value,
    );
    enabled = value;
    if (!value) {
      _setRing(null);
      await effect.stop();
      await _stopRing();
      if (kIsWeb) closeBrowserAudio();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _ring = null;
    _ringRevision++;
    await _stopRing();
    if (kIsWeb) closeBrowserAudio();
    await events?.cancel();
    await _ringWrites;
    await effect.dispose();
    await ringing.dispose();
  }
}
