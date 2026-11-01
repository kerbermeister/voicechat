import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/call_push.dart';

class PushClient extends Fake implements mx.Client {
  @override
  final http.Client httpClient;
  PushClient(this.httpClient);
  @override
  String get accessToken => 'fixture-token';
}

void main() {
  test('close waits for a late invite and its matching cancellation', () async {
    final invitation = Completer<void>();
    final canceled = Completer<void>();
    final actions = <String>[];
    final client = MockClient((request) async {
      expect(request.followRedirects, false);
      final body = jsonDecode(request.body) as Map;
      actions.add('${body['action']}:${body['session']}');
      if (body['action'] == 'invite') await invitation.future;
      if (body['action'] == 'end') await canceled.future;
      return http.Response('{}', 200);
    });
    final push = CallPush(PushClient(client), 'https://voice.example/api');
    final inviting = push.invite('old', '!room:local');
    var closed = false;
    final closing = push.endAll().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(actions, ['invite:old']);
    expect(closed, false);
    invitation.complete();
    await inviting;
    await Future<void>.delayed(Duration.zero);
    expect(actions, ['invite:old', 'end:old']);
    expect(closed, false);
    canceled.complete();
    await closing;
    expect(closed, true);
    client.close();
  });

  test(
    'canceling the old session cannot cancel a newer outgoing call',
    () async {
      final oldResponse = Completer<void>();
      final actions = <String>[];
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        actions.add('${body['action']}:${body['session']}');
        if (body['action'] == 'invite' && body['session'] == 'old') {
          await oldResponse.future;
        }
        return http.Response('{}', 200);
      });
      final push = CallPush(PushClient(client), 'https://voice.example/api');
      final old = push.invite('old', '!old:local');
      final endingOld = push.endOutgoing('old');
      expect(identical(push.endOutgoing('old'), endingOld), true);
      await push.invite('new', '!new:local');
      oldResponse.complete();
      await old;
      await endingOld;
      expect(actions, ['invite:old', 'invite:new', 'end:old']);
      await push.endAll();
      expect(actions.last, 'end:new');
      client.close();
    },
  );

  test(
    'a lost invite response still sends cancellation before shutdown',
    () async {
      final actions = <String>[];
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        actions.add(body['action'] as String);
        if (body['action'] == 'invite') {
          throw http.ClientException('lost response');
        }
        return http.Response('{}', 200);
      });
      final push = CallPush(PushClient(client), 'https://voice.example/api');
      await expectLater(
        push.invite('session', '!room:local'),
        throwsA(isA<http.ClientException>()),
      );
      await push.endAll();
      expect(actions, ['invite', 'end']);
      client.close();
    },
  );
}
