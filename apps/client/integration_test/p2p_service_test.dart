import 'dart:async';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/contact_service.dart';
import 'package:voicechat_probe/local_store.dart';
import 'package:voicechat_probe/matrix_probe.dart';
import 'package:voicechat_probe/p2p/service.dart';
import 'package:voicechat_probe/p2p/protocol.dart';
import 'package:voicechat_probe/picked_file.dart';

Future<void> until(bool Function() check) async {
  final end = DateTime.now().add(const Duration(seconds: 60));
  while (!check()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('P2P integration state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real encrypted Matrix offer, decline, first accepting device, file and room access revocation',
    (tester) async {
      const run = String.fromEnvironment('P2P_RUN');
      if (run.isEmpty) throw StateError('Use the disposable local P2P fixture');
      final probes = <MatrixProbe>[],
          contacts = <ContactService>[],
          services = <P2pService>[];
      try {
        for (var i = 0; i < 3; i++) {
          final probe = await MatrixProbe.open(
            'p2p-$run-$i',
            passphrase: 'disposable p2p test profile',
          );
          probes.add(probe);
          await probe.login(
            'http://localhost:8008',
            i == 0
                ? const String.fromEnvironment('P2P_SENDER_USER')
                : const String.fromEnvironment('P2P_RECEIVER_USER'),
            i == 0
                ? const String.fromEnvironment('P2P_SENDER_PASSWORD')
                : const String.fromEnvironment('P2P_RECEIVER_PASSWORD'),
          );
          final friends = ContactService(probe.client, 'http://localhost:8090');
          contacts.add(friends);
          await friends.open();
        }
        final a = probes[0], b = probes[1];
        final roomId = await a.startDirectChat(b.client.userID!);
        for (final receiver in probes.skip(1)) {
          await until(() => receiver.client.getRoomById(roomId) != null);
          if (receiver.client.getRoomById(roomId)!.membership ==
              mx.Membership.invite) {
            await receiver.client.joinRoom(roomId);
          }
          await receiver.room(roomId);
        }
        await contacts[0].request(b.client.userID!, roomId);
        for (final friends in contacts) {
          await friends.refresh();
        }
        for (final probe in probes) {
          for (final peer in probes) {
            await verifyDevice(
              probe.client,
              peer.client.userID!,
              peer.client.deviceID!,
              peer.client.fingerprintKey,
            );
          }
        }
        for (var i = 0; i < 3; i++) {
          final service = P2pService(
            probes[i].client,
            contacts[i],
            'http://localhost:8090',
          );
          services.add(service);
          await service.open();
        }
        final bytes = Uint8List.fromList(List.generate(65537, (i) => i % 251));
        var releases = 0;
        List<PickedFile> source() => [
          PickedFile(
            name: 'передача.bin',
            mime: 'application/octet-stream',
            size: bytes.length,
            read: (a, b) async => Uint8List.sublistView(bytes, a, b),
            release: () async {
              releases++;
            },
          ),
        ];
        await services[0].send([b.client.userID!], source());
        await until(
          () =>
              services[1].incomingCount == 1 && services[2].incomingCount == 1,
        );
        expect(services[1].transfers.single.wire, isNull);
        expect(services[0].transfers.single.bytes, [0]);
        await services[1].cancel(services[1].transfers.single, decline: true);
        await until(
          () => services[0].transfers.single.state == P2pState.declined,
        );
        await until(
          () => services[2].transfers.single.state == P2pState.cancelled,
        );
        expect(releases, 1);
        await services[0].send([b.client.userID!], source());
        await until(
          () =>
              services[1].transfers.length == 2 &&
              services[2].transfers.length == 2,
        );
        final incoming = services[1].transfers.last;
        await services[1].accept(incoming);
        await until(
          () =>
              services[0].transfers.last.state == P2pState.received &&
              incoming.state == P2pState.received,
        );
        await until(
          () => services[2].transfers.last.state == P2pState.cancelled,
        );
        expect(services[2].transfers.last.error, contains('другом устройстве'));
        expect(services[0].transfers.last.device, b.client.deviceID);
        expect(incoming.verified, [true]);
        expect(releases, 2);
        final hash = P2pHash();
        await for (final part in services[1].storage.range(
          incoming.id,
          0,
          bytes.length,
          0,
          bytes.length,
        )) {
          hash.input.add(part);
        }
        expect(hash.finish(), sha256.convert(bytes).toString());
        await services[0].send([b.client.userID!], source());
        await until(() => services[1].transfers.length == 3);
        await a.client.getRoomById(roomId)!.leave();
        await until(
          () =>
              services[0].transfers.last.state == P2pState.failed &&
              services[1].transfers.last.state == P2pState.failed,
        );
        expect(releases, 3);
      } finally {
        for (final service in services) {
          await service.close();
        }
        for (final friends in contacts) {
          await friends.close();
        }
        for (final probe in probes) {
          final name = probe.client.clientName;
          try {
            await probe.client.logout();
          } finally {
            await probe.close();
            await eraseStore(name);
          }
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
