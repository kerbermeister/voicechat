import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'call_controller.dart';

class MacOSNotifications {
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  static const channel = MethodChannel('voicechat/notifications');
  static MacOSNotifications? _current;
  final String account;
  final Future<void> Function(String) openRoom;
  final String session = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final _calls = <String>{};
  bool _closed = false;
  MacOSNotifications(this.account, this.openRoom);

  Future<void> open() async {
    if (!supported) return;
    _current = this;
    channel.setMethodCallHandler((call) async {
      final data = call.arguments;
      if (!_closed &&
          call.method == 'open' &&
          data is Map &&
          data['session'] == session &&
          data['room'] is String) {
        await openRoom(data['room'] as String);
      }
    });
    await channel.invokeMethod<void>('begin', {'session': session});
    final enabled =
        (await SharedPreferences.getInstance()).getBool(
          'macosNotifications:$account',
        ) ??
        false;
    if (!_closed) {
      await channel.invokeMethod<void>('enabled', {
        'session': session,
        'enabled': enabled,
      });
    }
  }

  Future<String> setEnabled(bool value) async {
    if (_closed) return 'Сеанс закрыт.';
    if (value) {
      final allowed =
          await channel.invokeMethod<bool>('request', {'session': session}) ??
          false;
      if (_closed) return 'Сеанс закрыт.';
      if (!allowed) {
        return 'Разрешите уведомления VoiceChat в системных настройках macOS.';
      }
    }
    await (await SharedPreferences.getInstance()).setBool(
      'macosNotifications:$account',
      value,
    );
    if (_closed) return 'Сеанс закрыт.';
    await channel.invokeMethod<void>('enabled', {
      'session': session,
      'enabled': value,
    });
    return value
        ? 'Уведомления включены, пока приложение работает.'
        : 'Уведомления выключены.';
  }

  Future<void> message(String room, String event) => _show(room, event, false);
  void updateCalls(CallController calls) {
    for (final call in calls.directInvitations) {
      if (_calls.add(call.session)) {
        unawaited(_show(call.chat.id, call.session, true));
      }
    }
    for (final call in calls.invitations.values) {
      if (_calls.add(call.session)) {
        unawaited(_show(call.room.id, call.session, true));
      }
    }
    if (_calls.length > 2000) _calls.remove(_calls.first);
  }

  Future<void> _show(String room, String id, bool call) async {
    if (_closed || !supported) return;
    try {
      await channel.invokeMethod<void>('show', {
        'session': session,
        'room': room,
        'id': id,
        'call': call,
      });
    } on PlatformException {
      // Notification permission or system delivery failure must not break sync/calls.
    }
  }

  Future<void> close() async {
    if (_closed || !supported) return;
    _closed = true;
    if (identical(_current, this)) {
      _current = null;
      channel.setMethodCallHandler(null);
    }
    await channel.invokeMethod<void>('end', {'session': session});
  }
}
