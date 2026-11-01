// Standalone local primitive probe. No application profiles, Matrix or key files.
import 'dart:convert';
import 'dart:io';
import 'package:vodozemac/vodozemac.dart' as crypto;

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
  stdout.writeln(
    jsonEncode({
      'result': 'PASS',
      'checks': [
        'history from first index',
        'current-only key rejects old history',
        'retained history key permits late join',
        'new epoch excludes old key',
        'wrong session rejects ciphertext',
      ],
      'deviceEnvelopeDeliveryChecked': false,
      'mediaDecryptionChecked': false,
      'persistentStorageUsed': false,
    }),
  );
}
