import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vodozemac/vodozemac.dart' as crypto;
import 'package:voicechat_probe/route_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/local_store.dart';
import 'package:voicechat_probe/matrix_probe.dart';
import 'package:voicechat_probe/route_transport.dart';
import 'package:voicechat_probe/route_config.dart';
import 'package:voicechat_probe/route_coordinator.dart';
import 'package:voicechat_probe/chunked_file.dart';
import 'route_file_probe.dart';

// This is a native SQLCipher/Keychain and Matrix SDK test. Its disposable
// Synapse and proxies are started by prototype/check_three_vps.py.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('encrypted Matrix profile survives proxy loss and reopen', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final routes = [
        Uri.parse(const String.fromEnvironment('ROUTE_TEST_B')),
        Uri.parse(const String.fromEnvironment('ROUTE_TEST_C')),
      ];
      for (final route in routes) {
        expect(route.scheme, 'http');
        expect(
          route.host,
          '127.0.0.1',
          reason: 'Never run against a remote service',
        );
        expect(route.port, greaterThan(1024));
      }
      // No server listens on this canonical origin; every request must route.
      final origin = Uri.parse('http://localhost:9');
      final suffix =
          '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 30)}';
      final profile = 'route_test_$suffix';
      final storeName = 'voicechat_probe_${Uri.encodeComponent(profile)}';
      final username = 'route_$suffix';
      final password = 'test-only-$suffix';
      final registrationTransport = RouteTransport(
        origin: origin,
        routes: routes,
        inner: http.Client(),
      );
      MatrixProbe? probe;
      final configuration = RouteConfig.parse(
        const String.fromEnvironment('ROUTE_CONFIG'),
      );
      RouteCoordinator? coordinator;
      try {
        final registration = MatrixApi(
          homeserver: origin,
          httpClient: registrationTransport,
        );
        await registration.register(
          username: username,
          password: password,
          inhibitLogin: true,
          auth: AuthenticationData(type: 'm.login.dummy'),
        );
        registrationTransport.close();
        probe = await MatrixProbe.open(profile);
        coordinator = probe.routes!;
        expect(coordinator.route(RouteService.matrix), isNotNull);
        expect(coordinator.route(RouteService.control), isNull);
        final discoveryDeadline = DateTime.now().add(
          const Duration(seconds: 10),
        );
        while (coordinator.config.edges.length != 3 &&
            DateTime.now().isBefore(discoveryDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          configuration.edges.length,
          const int.fromEnvironment(
            'ROUTE_TEST_BOOTSTRAP_COUNT',
            defaultValue: 2,
          ),
        );
        expect(coordinator.config.edges.map((e) => e.id), ['b', 'c', 'd']);
        checkSignedCatalog(configuration);
        await checkEncryptedFileRecovery();
        await probe
            .login(origin.toString(), username, password)
            .timeout(const Duration(seconds: 45));
        final device = probe.client.deviceID;
        final user = probe.client.userID;
        final token = probe.client.accessToken;
        final key = probe.client.fingerprintKey;
        expect(device, isNotNull);
        expect(key, isNotNull);
        final roomId = await probe.client.createRoom(
          initialState: [
            StateEvent(
              type: EventTypes.Encryption,
              stateKey: '',
              content: {'algorithm': 'm.megolm.v1.aes-sha2'},
            ),
          ],
        );
        final room = await waitRoom(probe.client, roomId);
        final before = await room.sendTextEvent(
          'before route change',
          parseCommands: false,
        );
        expect(before, isNotNull);
        final wire = await probe.client.getOneRoomEvent(roomId, before!);
        expect(wire.type, EventTypes.Encrypted);
        expect(wire.content.toString(), isNot(contains('before route change')));

        final filePlain = Uint8List.fromList(
          List.generate(4096, (i) => i % 251),
        );
        final encryptedFile = await MatrixFile(
          bytes: filePlain,
          name: 'route.bin',
        ).encrypt();
        final mxc = await probe.client.uploadContent(
          encryptedFile.data,
          filename: 'route.bin',
        );
        final fileContent = {
          'body': 'route.bin',
          'mime': 'application/octet-stream',
          'size': filePlain.length,
          'parts': [
            {
              'size': filePlain.length,
              'file': {
                'v': 'v2',
                'url': mxc.toString(),
                'key': {'k': encryptedFile.k},
                'iv': encryptedFile.iv,
                'hashes': {'sha256': encryptedFile.sha256},
              },
            },
          ],
        };
        expect(await ChunkedFile(probe.client, fileContent).part(0), filePlain);

        final faults = Uri.parse(
          const String.fromEnvironment('ROUTE_TEST_FAULTS'),
        );
        expect(faults.scheme, 'http');
        expect(faults.host, '127.0.0.1');
        expect(faults.port, greaterThan(1024));
        for (final id in ['b', 'c']) {
          final stopped = await http.post(
            faults.resolve('/stop/$id'),
            headers: {
              'Authorization':
                  'Bearer ${const String.fromEnvironment('ROUTE_TEST_FAULT_SECRET')}',
            },
          );
          expect(stopped.statusCode, 204);
        }
        // The background sync or this read detects the actual proxy outage.
        try {
          await probe.client.getTokenOwner();
        } on http.ClientException {
          // A failed request is not blindly replayed by the transport.
        }
        await coordinator.refresh();
        expect(coordinator.route(RouteService.matrix)!.id, 'd');
        expect((await probe.client.getTokenOwner()).deviceId, device);
        // A fresh reader forces an authenticated ciphertext download through D.
        expect(await ChunkedFile(probe.client, fileContent).part(0), filePlain);
        await expectDecryptedFromServer(room, before, 'before route change');
        final after = await room.sendTextEvent(
          'after route change',
          parseCommands: false,
        );
        expect(after, isNotNull);
        await expectDecryptedFromServer(room, after!, 'after route change');
        expect(probe.client.homeserver, origin);
        expect(probe.client.deviceID, device);
        expect(probe.client.fingerprintKey, key);
        await probe.close();
        probe = null;
        probe = await MatrixProbe.open(
          profile,
        ).timeout(const Duration(seconds: 45));
        coordinator = probe.routes!;
        expect(coordinator.config.edges.length, 3);
        expect(coordinator.route(RouteService.matrix)!.id, 'd');
        expect(probe.client.userID, user);
        expect(probe.client.deviceID, device);
        expect(probe.client.accessToken, token);
        expect(probe.client.fingerprintKey, key);
        final restored = await waitRoom(probe.client, roomId);
        expect(await ChunkedFile(probe.client, fileContent).part(0), filePlain);
        await expectDecryptedFromServer(
          restored,
          before,
          'before route change',
        );
        await expectDecryptedFromServer(restored, after, 'after route change');
        expect(await probe.client.getDevices(), hasLength(1));
      } finally {
        registrationTransport.close();
        await probe?.close();
        coordinator?.close();
        // Only the uniquely named synthetic profile created by this test.
        await eraseStore(storeName);
        await (await SharedPreferences.getInstance()).remove(
          'route-catalog:${configuration.serviceId}:${const String.fromEnvironment('ROUTE_CATALOG_KEY')}',
        );
      }
    });
  }, timeout: const Timeout(Duration(minutes: 4)));
}

Future<void> expectDecryptedFromServer(
  Room room,
  String eventId,
  String body,
) async {
  // Fetch ciphertext again: cached plaintext does not prove restored keys work.
  final wire = await room.client.getOneRoomEvent(room.id, eventId);
  expect(wire.type, EventTypes.Encrypted);
  expect(wire.content.toString(), isNot(contains(body)));
  final decrypted = await room.client.encryption!.decryptRoomEvent(
    Event.fromMatrixEvent(wire, room),
  );
  expect(decrypted.type, EventTypes.Message);
  expect(decrypted.body, body);
}

Future<Room> waitRoom(Client client, String roomId) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    final room = client.getRoomById(roomId);
    if (room != null && room.encrypted) return room;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException('Encrypted room did not appear in sync');
}

void checkSignedCatalog(RouteConfig bootstrap) {
  final signer = crypto.PkSigning();
  final key = base64Encode(signer.publicKey.toBytes());
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final topology = jsonDecode(const String.fromEnvironment('ROUTE_CONFIG'));
  String signed(int revision, {int? expires, String? service}) {
    final value = jsonDecode(jsonEncode(topology));
    if (service != null) value['service_id'] = service;
    final payload = jsonEncode({
      'schema': 1,
      'revision': revision,
      'issued_at': now - 10,
      'expires_at': expires ?? now + 3600,
      'topology': value,
    });
    return jsonEncode({
      'payload': base64Encode(utf8.encode(payload)),
      'signature': base64Encode(
        signer.sign(routeCatalogDomain + payload).toBytes(),
      ),
    });
  }

  final current = verifyRouteCatalog(signed(2), key, bootstrap);
  expect(current.revision, 2);
  expect(
    () => verifyRouteCatalog(signed(1), key, bootstrap, previous: current),
    throwsFormatException,
  );
  expect(
    () => verifyRouteCatalog(
      signed(2, expires: now + 2000),
      key,
      bootstrap,
      previous: current,
    ),
    throwsFormatException,
  );
  expect(
    () => verifyRouteCatalog(signed(3, service: 'foreign'), key, bootstrap),
    throwsFormatException,
  );
  expect(
    () => verifyRouteCatalog(signed(3, expires: now - 1), key, bootstrap),
    throwsFormatException,
  );
  expect(
    verifyRouteCatalog(
      signed(2, expires: now - 1),
      key,
      bootstrap,
      restoring: true,
    ).revision,
    2,
  );
  final tampered = jsonDecode(signed(3));
  tampered['payload'] = base64Encode(utf8.encode('{}'));
  expect(
    () => verifyRouteCatalog(jsonEncode(tampered), key, bootstrap),
    throwsA(anything),
  );
  expect(
    () => verifyRouteCatalog(
      signed(3),
      base64Encode(crypto.PkSigning().publicKey.toBytes()),
      bootstrap,
    ),
    throwsA(anything),
  );
}
