import 'dart:js_interop';
import 'transport.dart';
import 'user_action_error.dart';

@JS('VoiceChatPush.enable')
external JSPromise<JSString> _enable(JSString base, JSString token);
@JS('VoiceChatPush.disable')
external JSPromise<JSString> _disable(JSString base, JSString token);
Future<String> _change(String url, String token, bool enabled) async {
  secureEndpoint(url);
  try {
    final pending = enabled
        ? _enable(url.toJS, token.toJS)
        : _disable(url.toJS, token.toJS);
    return (await pending.toDart).toDart;
  } catch (error) {
    throw UserActionError(error.toString().replaceFirst('Error: ', ''));
  }
}

Future<String> enablePushNotifications(String url, String token) =>
    _change(url, token, true);
Future<String> disablePushNotifications(String url, String token) =>
    _change(url, token, false);
