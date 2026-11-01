import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'call_controller.dart';

class NativeNotifications {
  static bool get supported =>
      !kIsWeb &&
      {
        TargetPlatform.macOS,
        TargetPlatform.android,
      }.contains(defaultTargetPlatform);
  static const channel = MethodChannel('voicechat/notifications');
  static NativeNotifications? _current;
  final String account;
  String get _preference => defaultTargetPlatform == TargetPlatform.macOS
      ? 'macosNotifications:$account'
      : 'androidNotifications:$account';
  final Future<void> Function(String) openRoom;
  final String session = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final _calls = <String>{};
  bool _closed = false;
  bool _enabled = false;
  bool _pushBound = false;
  Map<String, dynamic>? _pendingPush;
  bool _answeringPush = false;
  Future<void>? _registration;
  int _pushGeneration = 0;
  final String? pushUrl;
  final String? accessToken;
  final http.Client? transport;
  final void Function(String)? report;
  NativeNotifications(
    this.account,
    this.openRoom, {
    this.pushUrl,
    this.accessToken,
    this.transport,
    this.report,
  });
  bool get _android => defaultTargetPlatform == TargetPlatform.android;

  Future<void> open() async {
    if (!supported) return;
    _current = this;
    channel.setMethodCallHandler((call) async {
      final data = call.arguments;
      if (!_closed && call.method == 'pushAvailable') {
        await _takePush();
        return;
      }
      if (!_closed && call.method == 'tokenChanged' && _enabled) {
        try {
          await _registerPush();
        } catch (_) {
          report?.call(
            'Не удалось обновить фоновые уведомления. Повторите включение при доступной сети.',
          );
        }
        return;
      }
      if (!_closed &&
          call.method == 'open' &&
          data is Map &&
          data['session'] == session &&
          data['room'] is String) {
        await openRoom(data['room'] as String);
      }
    });
    await channel.invokeMethod<void>('begin', {
      'session': session,
      'account': account,
    });
    final enabled =
        (await SharedPreferences.getInstance()).getBool(_preference) ?? false;
    if (!_closed) {
      _enabled = enabled;
      if (_android && enabled) {
        try {
          await _registerPush();
        } catch (_) {
          report?.call(
            'Фоновые уведомления недоступны. Проверьте сеть и повторите включение.',
          );
        }
      }
      await channel.invokeMethod<void>('enabled', {
        'session': session,
        'enabled': enabled,
      });
      if (_android) await _takePush();
    }
  }

  Future<String> setEnabled(bool value) async {
    if (_closed) return 'Сеанс закрыт.';
    if (!value) _enabled = false;
    if (value) {
      final allowed =
          await channel.invokeMethod<bool>('request', {'session': session}) ??
          false;
      if (_closed) return 'Сеанс закрыт.';
      if (!allowed) {
        return 'Разрешите уведомления VoiceChat в системных настройках устройства.';
      }
    }
    if (_android && value) {
      try {
        await _registerPush();
      } catch (_) {
        return 'Не удалось подключить фоновые уведомления. Проверьте сеть и попробуйте снова.';
      }
    } else if (_android && !value) {
      await unregisterPush();
    }
    if (_closed) return 'Сеанс закрыт.';
    _enabled = value;
    await (await SharedPreferences.getInstance()).setBool(_preference, value);
    if (_closed) return 'Сеанс закрыт.';
    await channel.invokeMethod<void>('enabled', {
      'session': session,
      'enabled': value,
    });
    if (value && _android && _pushBound) {
      final fullScreen = await channel.invokeMethod<bool>('requestCallScreen', {
        'session': session,
      });
      if (fullScreen == false) {
        return 'Фоновые уведомления включены. Разрешите полноэкранные вызовы в настройках Android.';
      }
    }
    return value
        ? _pushBound
              ? 'Фоновые уведомления включены.'
              : 'Уведомления включены, пока приложение работает.'
        : 'Уведомления выключены.';
  }

  Future<void> _registerPush() => _registration ??= _doRegisterPush()
      .whenComplete(() => _registration = null);

  Future<void> _doRegisterPush() async {
    if (pushUrl == null || accessToken == null || transport == null) return;
    final generation = _pushGeneration;
    final token = await channel
        .invokeMethod<String>('pushToken', {'session': session})
        .timeout(const Duration(seconds: 15));
    if (_closed || generation != _pushGeneration || token == null) {
      throw StateError('FCM token unavailable');
    }
    final response = await _pushRequest({
      'action': 'register',
      'token': token,
    }).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200 || response.bodyBytes.length > 8192) {
      throw StateError('FCM registration failed');
    }
    final binding = (jsonDecode(response.body) as Map)['binding'];
    if (binding is! String || binding.length != 43) {
      throw const FormatException();
    }
    if (_closed || generation != _pushGeneration) return;
    await channel.invokeMethod<void>('pushBind', {
      'session': session,
      'account': account,
      'base': pushUrl,
      'binding': binding,
    });
    _pushBound = true;
  }

  Future<void> unregisterPush() async {
    if (!_android) return;
    _enabled = false;
    _pushGeneration++;
    await channel.invokeMethod<void>('pushClear', {'session': session});
    _pushBound = false;
    try {
      await _registration;
    } catch (_) {
      /* Remove the registration even after a lost response. */
    }
    if (pushUrl == null || accessToken == null || transport == null) return;
    try {
      await _pushRequest({
        'action': 'remove',
      }).timeout(const Duration(seconds: 10));
    } catch (_) {
      // Local binding is already gone; queued pushes cannot display on this installation.
    }
  }

  Future<http.Response> _pushRequest(Map<String, dynamic> body) {
    final request = http.Request('POST', Uri.parse('$pushUrl/push/android'))
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      })
      ..body = jsonEncode(body);
    return transport!.send(request).then(http.Response.fromStream);
  }

  Future<void> _takePush() async {
    final data = await channel.invokeMapMethod<String, dynamic>('takePush', {
      'session': session,
    });
    if (_closed || data == null) return;
    if (data['room'] is String) await openRoom(data['room'] as String);
    if (data['action'] == 'answer') _pendingPush = data;
  }

  Future<void> message(String room, String event) => _show(room, event, false);
  void updateCalls(CallController calls) {
    if (_android && !_answeringPush) unawaited(_applyPush(calls));
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

  Future<void> _applyPush(CallController calls) async {
    _answeringPush = true;
    try {
      await _takePush();
      final data = _pendingPush;
      if (_closed || data == null) return;
      final expires = data['expires'];
      if (expires is! int ||
          expires * 1000 <= DateTime.now().millisecondsSinceEpoch) {
        _pendingPush = null;
        return;
      }
      final session = data['session'];
      for (final call in calls.directInvitations.toList()) {
        if (call.session == session && call.chat.id == data['room']) {
          _pendingPush = null;
          if (data['video'] != call.video) {
            report?.call('Тип вызова изменился. Ответьте в приложении.');
            return;
          }
          await calls.acceptDirect(call);
          return;
        }
      }
      final invitation = calls.invitations[session];
      if (invitation != null && invitation.room.id == data['room']) {
        _pendingPush = null;
        if (data['video'] != invitation.video) {
          report?.call('Тип вызова изменился. Ответьте в приложении.');
          return;
        }
        await calls.start(invitation.room, invitation: invitation);
      }
    } catch (_) {
      report?.call(
        'Не удалось ответить из уведомления. Откройте вызов в приложении.',
      );
    } finally {
      _answeringPush = false;
    }
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
    if (_android) await unregisterPush();
    if (identical(_current, this)) {
      _current = null;
      channel.setMethodCallHandler(null);
    }
    await channel.invokeMethod<void>('end', {'session': session});
  }
}
