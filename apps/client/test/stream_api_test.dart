import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voicechat_probe/stream_api.dart';
import 'package:voicechat_probe/stream_state.dart';

Map<String, dynamic> snapshot() => {
  'owner_device': 'phone',
  'generation': 'generation',
  'key_epoch': 1,
  'id': 'stream',
  'owner': '@alice:local',
  'title': 'test',
  'description': '',
  'state': 'live',
  'revision': 1,
  'viewers': 1,
  'comments': true,
  'started_at': 1000.0,
  'ends_at': 1100.0,
  'server_now': 1025.0,
};

void main() {
  test(
    'server snapshot and elapsed progress do not depend on phone wall clock',
    () {
      final state = LiveStreamSnapshot.parse(snapshot());
      expect(state.progress(), .25);
      expect(state.progress(const Duration(seconds: 25)), .5);
      expect(state.remaining(const Duration(seconds: 80)), Duration.zero);
      expect(state.progress(const Duration(seconds: 80)), 1);
      expect(state.viewerUsers, isNull);
    },
  );
  test('invalid state, roster, time and deadline are rejected', () {
    for (final change in [
      {'state': 'unknown'},
      {'revision': true},
      {'viewers': 11},
      {
        'viewer_users': ['a', 'a'],
      },
      {'server_now': double.nan},
      {'ends_at': 900},
      {'server_now': 999},
      {'comments': 'yes'},
    ]) {
      expect(
        () => LiveStreamSnapshot.parse({...snapshot(), ...change}),
        throwsFormatException,
      );
    }
  });
  test('bearer remains a header and server errors remain errors', () async {
    final api = LiveStreamApi(
      'http://127.0.0.1:8090',
      () => 'fixture-secret',
      client: MockClient((request) async {
        expect(request.url.toString(), 'http://127.0.0.1:8090/streams');
        expect(request.headers['Authorization'], 'Bearer fixture-secret');
        final body = jsonDecode(request.body);
        expect(body['protocol_version'], 1);
        expect(body['operation'], 'join');
        return http.Response('{"error":"stream_full"}', 409);
      }),
    );
    addTearDown(api.close);
    await expectLater(
      api.command('join', {'stream_id': 'id'}),
      throwsA(
        isA<LiveStreamError>().having((e) => e.code, 'code', 'stream_full'),
      ),
    );
  });
  test(
    'encrypted comment metadata is bounded and its epoch remains public',
    () {
      final value = {
        'sequence': 1,
        'id': 'message',
        'author': '@a:local',
        'device': 'A',
        'ciphertext': base64Encode(utf8.encode('{"epoch":7,"body":[]}')),
      };
      expect(LiveStreamEncryptedComment.parse(value).epoch, 7);
      for (final change in [
        {'sequence': true},
        {'ciphertext': '%%%'},
        {'device': ''},
      ]) {
        expect(
          () => LiveStreamEncryptedComment.parse({...value, ...change}),
          throwsFormatException,
        );
      }
    },
  );
  test('production control prefix is preserved', () async {
    final api = LiveStreamApi(
      'https://example.test/api/',
      () => 'fixture',
      client: MockClient((request) async {
        expect(request.url.path, '/api/streams');
        return http.Response('{}', 200);
      }),
    );
    addTearDown(api.close);
    await api.capabilities();
  });
  test('capabilities and malformed responses', () async {
    final api = LiveStreamApi(
      'https://example.test',
      () => 'fixture',
      client: MockClient((request) async => http.Response('[]', 200)),
    );
    addTearDown(api.close);
    await expectLater(api.capabilities(), throwsFormatException);
    expect(
      () => LiveStreamApi('http://example.test', () => ''),
      throwsArgumentError,
    );
  });
}
