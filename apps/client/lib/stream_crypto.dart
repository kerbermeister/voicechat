import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:vodozemac/vodozemac.dart' as vod;

const streamCommentDomain = 'voicechat-stream-comment-v1\n';
const streamKeysType = 'dev.voicechat.stream.keys.v1';

/// Stream-only keys. Never use Matrix room sessions, pickles or a database here.
class LiveStreamCrypto {
  final String stream;
  final int endsAt;
  final _secrets = <int, Uint8List>{};
  final _decryption = <int, vod.PkDecryption>{};
  Uint8List? mediaKey;
  int epoch = 0;
  LiveStreamCrypto(this.stream, this.endsAt);

  void createEpoch(int next) {
    if (next <= epoch || next > 9007199254740991) {
      throw const FormatException('stream epoch');
    }
    final decryption = vod.PkDecryption();
    _secrets[next] = decryption.privateKey;
    _decryption[next] = decryption;
    mediaKey?.fillRange(0, mediaKey!.length, 0);
    mediaKey = Uint8List.fromList(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    );
    epoch = next;
  }

  Map<String, dynamic> exportBundle() => {
    'protocol_version': 1,
    'stream': stream,
    'ends_at': endsAt,
    'epoch': epoch,
    'media': base64Encode(mediaKey!),
    'history': [
      for (final entry in _secrets.entries)
        {'epoch': entry.key, 'secret': base64Encode(entry.value)},
    ],
  };

  void importBundle(Map<String, dynamic> data, int expectedEpoch) {
    if (data['protocol_version'] is! int ||
        data['protocol_version'] != 1 ||
        data['epoch'] is! int ||
        data['ends_at'] is! int ||
        expectedEpoch < 1 ||
        data['stream'] != stream ||
        data['ends_at'] != endsAt ||
        data['epoch'] != expectedEpoch ||
        expectedEpoch < epoch ||
        expectedEpoch > 9007199254740991 ||
        data['history'] is! List ||
        (data['history'] as List).length > 8192) {
      throw const FormatException('stream keys');
    }
    Uint8List key(Object? value) {
      if (value is! String || value.length != 44) {
        throw const FormatException('stream key');
      }
      final bytes = base64Decode(value);
      if (bytes.length != 32) throw const FormatException('stream key');
      return bytes;
    }

    final nextMedia = key(data['media']);
    final nextSecrets = <int, Uint8List>{};
    for (final entry in data['history'] as List) {
      if (entry is! Map ||
          entry['epoch'] is! int ||
          entry['epoch'] < 1 ||
          entry['epoch'] > expectedEpoch ||
          nextSecrets.containsKey(entry['epoch'])) {
        throw const FormatException('stream history keys');
      }
      final number = entry['epoch'] as int;
      final secret = key(entry['secret']);
      if (_secrets.containsKey(number) &&
          base64Encode(_secrets[number]!) != base64Encode(secret)) {
        throw const FormatException('stream history key changed');
      }
      nextSecrets[number] = secret;
    }
    if (!nextSecrets.containsKey(expectedEpoch) ||
        !_secrets.keys.every(nextSecrets.containsKey)) {
      throw const FormatException('stream history key missing');
    }
    mediaKey?.fillRange(0, mediaKey!.length, 0);
    for (final secret in _secrets.values) {
      secret.fillRange(0, secret.length, 0);
    }
    _secrets.clear();
    _decryption.clear();
    _secrets.addAll(nextSecrets);
    for (final entry in nextSecrets.entries) {
      _decryption[entry.key] = vod.PkDecryption.fromSecretKey(
        vod.Curve25519PublicKey.fromBytes(entry.value),
      );
    }
    mediaKey = nextMedia;
    epoch = expectedEpoch;
  }

  Uint8List encryptComment({
    required String text,
    required String id,
    required String author,
    required String device,
    required String Function(String) sign,
  }) {
    if (text.trim().isEmpty || text.runes.length > 1000 || epoch == 0) {
      throw const FormatException('stream comment');
    }
    final encrypted = vod.PkEncryption.fromPublicKey(
      vod.Curve25519PublicKey.fromBase64(_decryption[epoch]!.publicKey),
    ).encrypt(text).toBase64();
    final body = [encrypted.$1, encrypted.$2, encrypted.$3];
    final signed = jsonEncode([stream, epoch, id, author, device, body]);
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'epoch': epoch,
          'body': body,
          'signature': sign(streamCommentDomain + signed),
        }),
      ),
    );
  }

  String decryptComment({
    required List<int> ciphertext,
    required String id,
    required String author,
    required String device,
    required vod.Ed25519PublicKey signingKey,
  }) {
    if (ciphertext.isEmpty || ciphertext.length > 8192) {
      throw const FormatException('stream comment');
    }
    final value = jsonDecode(utf8.decode(ciphertext));
    if (value is! Map<String, dynamic> ||
        value['v'] is! int ||
        value['v'] != 1 ||
        value['epoch'] is! int ||
        value['body'] is! List ||
        (value['body'] as List).length != 3 ||
        (value['body'] as List).any((v) => v is! String) ||
        value['signature'] is! String) {
      throw const FormatException('stream comment');
    }
    final number = value['epoch'] as int;
    final decryption = _decryption[number];
    if (decryption == null) throw const FormatException('stream key missing');
    final body = (value['body'] as List).cast<String>();
    signingKey.verify(
      message:
          streamCommentDomain +
          jsonEncode([stream, number, id, author, device, body]),
      signature: vod.Ed25519Signature.fromBase64(value['signature']),
    );
    final text = decryption.decrypt(
      vod.PkMessage.fromBase64(
        ciphertext: body[0],
        mac: body[1],
        ephemeralKey: body[2],
      ),
    );
    if (text.trim().isEmpty || text.runes.length > 1000) {
      throw const FormatException('stream text');
    }
    return text;
  }

  void clear() {
    mediaKey?.fillRange(0, mediaKey!.length, 0);
    mediaKey = null;
    for (final secret in _secrets.values) {
      secret.fillRange(0, secret.length, 0);
    }
    _secrets.clear();
    _decryption.clear();
    epoch = 0;
  }
}
