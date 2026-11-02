// Standalone local primitive probe. No application profiles, Matrix or key files.
import 'dart:convert';
import 'dart:io';
import 'package:vodozemac/vodozemac.dart' as crypto;
import 'package:voicechat_probe/stream_crypto.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void mustReject(void Function() operation, String message) {
  var rejected = false;
  try {
    operation();
  } catch (_) {
    rejected = true;
  }
  require(rejected, message);
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    throw ArgumentError('Expected native library directory and stem');
  }
  await crypto.init(
    libraryPath: Uri.directory(arguments[0]).toFilePath(),
    stem: arguments[1],
  );
  final sender = crypto.GroupSession();
  final retained = sender.toInbound();
  final first = sender.encrypt('ephemeral first comment');
  final second = sender.encrypt('ephemeral second comment');
  require(
    retained.decrypt(first).plaintext == 'ephemeral first comment',
    'first decrypt',
  );
  final currentOnly = crypto.InboundGroupSession(sender.sessionKey);
  mustReject(
    () => currentOnly.decrypt(first),
    'current key must not imply old history',
  );

  // Actual authorisation and device-envelope delivery are separate gates.
  final late = crypto.InboundGroupSession.import(
    retained.exportAtFirstKnownIndex(),
  );
  require(
    late.decrypt(first).plaintext == 'ephemeral first comment',
    'late first',
  );
  require(
    late.decrypt(second).plaintext == 'ephemeral second comment',
    'late second',
  );
  require(late.firstKnownIndex == 0, 'history starts at zero');
  final nextEpoch = crypto.GroupSession();
  final permitted = nextEpoch.toInbound();
  final future = nextEpoch.encrypt('after access revocation');
  mustReject(
    () => late.decrypt(future),
    'old history key must not decrypt next epoch',
  );
  require(
    permitted.decrypt(future).plaintext == 'after access revocation',
    'new epoch',
  );
  mustReject(
    () => crypto.GroupSession().toInbound().decrypt(first),
    'wrong session',
  );
  final identity = crypto.Account();
  final host = LiveStreamCrypto('stream-fixture', 123456);
  final viewer = LiveStreamCrypto('stream-fixture', 123456);
  host.createEpoch(1);
  final comment = host.encryptComment(
    text: 'stream-only text',
    id: 'one',
    author: '@a:local',
    device: 'A',
    sign: (value) => identity.sign(value).toBase64(),
  );
  viewer.importBundle(host.exportBundle(), 1);
  String decrypt(LiveStreamCrypto keys, {String author = '@a:local'}) =>
      keys.decryptComment(
        ciphertext: comment,
        id: 'one',
        author: author,
        device: 'A',
        signingKey: identity.identityKeys.ed25519,
      );
  require(decrypt(viewer) == 'stream-only text', 'production chat decrypt');
  mustReject(() => decrypt(viewer, author: '@forged:local'), 'forged author');
  host.createEpoch(2);
  final nextComment = host.encryptComment(
    text: 'new epoch',
    id: 'two',
    author: '@a:local',
    device: 'A',
    sign: (value) => identity.sign(value).toBase64(),
  );
  mustReject(
    () => viewer.decryptComment(
      ciphertext: nextComment,
      id: 'two',
      author: '@a:local',
      device: 'A',
      signingKey: identity.identityKeys.ed25519,
    ),
    'old viewer excluded',
  );
  final lateViewer = LiveStreamCrypto('stream-fixture', 123456);
  lateViewer.importBundle(host.exportBundle(), 2);
  require(
    decrypt(lateViewer) == 'stream-only text',
    'production full late history',
  );
  mustReject(
    () => LiveStreamCrypto(
      'wrong-stream',
      123456,
    ).importBundle(host.exportBundle(), 2),
    'cross stream key replay',
  );
  host.clear();
  viewer.clear();
  lateViewer.clear();
  require(host.mediaKey == null && host.epoch == 0, 'key cleanup');
  stdout.writeln(
    jsonEncode({
      'result': 'PASS',
      'checks': [
        'history from first index',
        'current-only key rejects old history',
        'retained history key permits late join',
        'new epoch excludes old key',
        'wrong session rejects ciphertext',
        'production signed chat roundtrip',
        'forged author rejected',
        'production history after rekey',
        'cross-stream key replay rejected',
        'RAM key cleanup',
      ],
      'deviceEnvelopeDeliveryChecked': false,
      'mediaDecryptionChecked': false,
      'persistentStorageUsed': false,
    }),
  );
}
