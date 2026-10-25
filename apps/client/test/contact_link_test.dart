import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/contact_link.dart';
import 'package:voicechat_probe/contact_link_dialog.dart';
import 'package:voicechat_probe/contact_service.dart';
import 'package:voicechat_probe/matrix_probe.dart';
import 'package:voicechat_probe/theme.dart';
import 'chat_actions_test.dart' show OutboxDatabase, OutboxRoom;

final origin = Uri.parse('https://chat.example');
final token = 'a' * 43;
Map<String, dynamic> receipt({bool sent = false}) => {
  'id': 'b' * 64,
  'owner': '@owner:local',
  'claimed': true,
  'accepted': true,
  'room_id': '!test:local',
  'prepared': !sent,
  'event_id': sent ? r'$sent' : null,
};

class LinkClient extends Client {
  LinkClient({required super.httpClient, required super.database})
    : super('link-test');
  @override
  String get userID => '@user:local';
}

class LinkRoom extends OutboxRoom {
  LinkRoom(super.client);
  @override
  Future<void> postLoad() async {}
  @override
  String get directChatMatrixID => '@owner:local';
  @override
  Future<void> addToDirectChat(
    String userID, {
    bool waitForSync = false,
  }) async {}
}

class LinkProbe extends MatrixProbe {
  LinkProbe(super.client);
  @override
  Future<Room> room(String id) async => LinkRoom(client);
}

class LinkContacts extends ContactService {
  LinkContacts(Client client) : super(client, 'https://chat.example/api');
  @override
  Future<void> refresh() async {}
}

class DialogLinks extends ContactLinks {
  int created = 0;
  int accepted = 0;
  int inspected = 0;
  DialogLinks(Client client)
    : super(LinkProbe(client), LinkContacts(client), origin);
  @override
  Future<Uri> create() async {
    created++;
    return contactLinkUrl(origin, token);
  }

  @override
  Future<Map<String, dynamic>> inspect(String token) async {
    inspected++;
    return receipt();
  }

  @override
  Future<Room> accept(String token) async {
    accepted++;
    return LinkRoom(client);
  }
}

void main() {
  testWidgets(
    'Share opens platform chooser with the existing link, without minting another',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <MethodCall>[];
      const channel = MethodChannel('voicechat/links');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final client = LinkClient(
        database: OutboxDatabase(),
        httpClient: MockClient((_) async => http.Response('{}', 500)),
      );
      final links = DialogLinks(client);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(body: ContactLinkDialog(links: links, create: true)),
        ),
      );
      expect(find.text('Поделиться'), findsNothing);
      await tester.tap(find.text('Создать ссылку'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Поделиться'));
      await tester.pumpAndSettle();
      expect(calls.single.method, 'share');
      expect(calls.single.arguments, contactLinkUrl(origin, token).toString());
      expect(links.created, 1);
      expect(
        find.text(contactLinkUrl(origin, token).toString()),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  test('Only same-server HTTPS invitation fragments are accepted', () {
    final url = contactLinkUrl(origin, token);
    expect(url.query, isEmpty);
    expect(url.path, '/');
    expect(contactLinkToken(url.toString(), origin), token);
    for (final value in [
      'not a link',
      'javascript:alert(1)',
      'https://other.example/#/contact/$token',
      'http://chat.example/#/contact/$token',
      'https://user@chat.example/#/contact/$token',
      'https://chat.example/path#/contact/$token',
      'https://chat.example/?x=1#/contact/$token',
      'https://chat.example/#/contact/${token}x',
      'https://chat.example/#/contact/',
    ]) {
      expect(() => contactLinkToken(value, origin), throwsA(isA<StateError>()));
    }
  });

  test(
    'Lost greeting acknowledgement resumes persisted envelope without re-encryption',
    () async {
      final db = OutboxDatabase();
      var offline = true;
      var sent = false;
      final requests = <Map<String, dynamic>>[];
      final client = LinkClient(
        database: db,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/contact-links');
          expect(request.method, 'POST');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          requests.add(body);
          if (body['action'] == 'inspect') {
            return http.Response(jsonEncode(receipt(sent: sent)), 200);
          }
          expect(body, {'action': 'greet', 'id': 'b' * 64});
          if (offline) {
            return http.Response('{"error":"contacts_unavailable"}', 503);
          }
          sent = true;
          return http.Response('{"event_id":"\$sent"}', 200);
        }),
      );
      ContactLinks service() =>
          ContactLinks(LinkProbe(client), LinkContacts(client), origin);
      await expectLater(service().accept(token), throwsStateError);
      expect(await service().pending(), token);
      offline = false;
      await service().accept(token);
      expect(await service().pending(), isNull);
      await service().accept(token);
      expect(requests.where((r) => r['action'] == 'greet'), hasLength(2));
      expect(requests.any((r) => r.containsKey('payload')), false);
      expect(requests.any((r) => r['action'] == 'accept'), false);
    },
  );

  testWidgets(
    'Preview never accepts; explicit button works at 320px and text 200%',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = LinkClient(
        database: OutboxDatabase(),
        httpClient: MockClient((_) async => http.Response('{}', 500)),
      );
      for (final palette in AppPalette.values) {
        final links = DialogLinks(client);
        await tester.pumpWidget(
          MaterialApp(
            theme: palette.theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<Room>(
                    context: context,
                    builder: (_) => ContactLinkDialog(
                      links: links,
                      initialLink: contactLinkUrl(origin, token).toString(),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(links.inspected, 1);
        expect(links.accepted, 0);
        expect(find.text('@owner:local'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final accept = find.text('Добавить и отправить «Привет»');
        await tester.ensureVisible(accept);
        await tester.tap(accept);
        await tester.pumpAndSettle();
        expect(links.accepted, 1);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
