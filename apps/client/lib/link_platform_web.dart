import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;
import 'transport.dart';
import 'user_action_error.dart';

Future<void> shareLink(Uri url) {
  secureEndpoint(url.removeFragment().toString());
  const unavailable =
      'Меню «Поделиться» недоступно. Нажмите на ссылку, чтобы скопировать её, и вставьте в нужный мессенджер.';
  if (!web.window.navigator.has('share') ||
      web.window.navigator
          .getProperty<JSAny?>('share'.toJS)
          .isUndefinedOrNull) {
    throw UserActionError(unavailable);
  }
  final done = Completer<void>();
  // Call in the button's user gesture; awaiting any API request first loses activation.
  web.window.navigator
      .share(
        web.ShareData(title: 'Приглашение в VoiceChat', url: url.toString()),
      )
      .callMethod<JSAny?>(
        'then'.toJS,
        ((JSAny? _) {
          done.complete();
        }).toJS,
        ((JSAny? error) {
          final name = error == null
              ? null
              : (error as JSObject).getProperty<JSString?>('name'.toJS)?.toDart;
          if (name == 'AbortError') {
            done.complete();
          } else {
            done.completeError(UserActionError(unavailable));
          }
        }).toJS,
      );
  return done.future;
}

Future<void> openLink(Uri url) async {
  if (!['http', 'https'].contains(url.scheme) ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty) {
    throw const FormatException('Invalid link');
  }
  web.window.open(url.toString(), '_blank', 'noopener,noreferrer');
}
