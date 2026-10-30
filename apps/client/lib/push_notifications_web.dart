import 'dart:js_interop';
import 'package:http/http.dart' as http;
import 'push_api.dart';
import 'transport.dart';
import 'user_action_error.dart';

@JS('VoiceChatPush.enable')
external JSPromise<JSString> _enable(
  JSString base,
  JSString token,
  JSFunction? request,
);
@JS('VoiceChatPush.disable')
external JSPromise<JSString> _disable(
  JSString base,
  JSString token,
  JSFunction? request,
);
Future<String> _change(
  String url,
  String token,
  bool enabled,
  http.Client Function()? createClient,
) async {
  secureEndpoint(url);
  final client = createClient?.call();
  final request = client == null
      ? null
      : ((JSString path, JSString? body) => requestPush(
          client,
          url,
          token,
          path.toDart,
          body?.toDart,
        ).then((value) => value.toJS).toJS).toJS;
  try {
    // Invoke before awaiting: permission must retain the click's activation.
    final pending = enabled
        ? _enable(url.toJS, token.toJS, request)
        : _disable(url.toJS, token.toJS, request);
    return (await pending.toDart).toDart;
  } catch (error) {
    throw UserActionError(error.toString().replaceFirst('Error: ', ''));
  } finally {
    client?.close();
  }
}

Future<String> enablePushNotifications(
  String url,
  String token, {
  http.Client Function()? createClient,
}) => _change(url, token, true, createClient);
Future<String> disablePushNotifications(
  String url,
  String token, {
  http.Client Function()? createClient,
}) => _change(url, token, false, createClient);
