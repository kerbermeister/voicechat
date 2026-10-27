import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

const p2pBlockBytes = 4 * 1024 * 1024;
const p2pFrameBytes = 16 * 1024;
const p2pHeaderBytes = 16;
const p2pManifestBytes = 65536;
const p2pInvitationSeconds = 300;

int boundedInt(Object? value, int min, int max) {
  if (value is! int || value < min || value > max) {
    throw const FormatException('Invalid P2P integer');
  }
  return value;
}

String p2pId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

bool validP2pId(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{32}$').hasMatch(value);

class P2pPolicy {
  final int maxBytes, maxFiles, maxRecipients;
  const P2pPolicy(this.maxBytes, this.maxFiles, this.maxRecipients);
  static P2pPolicy? parse(Map<String, dynamic> json) {
    const keys = [
      'p2p_file_max_bytes',
      'p2p_file_max_count',
      'p2p_max_recipients',
    ];
    if (keys.every((key) => !json.containsKey(key))) return null;
    return P2pPolicy(
      boundedInt(json[keys[0]], 1, 100000000000),
      boundedInt(json[keys[1]], 1, 100),
      boundedInt(json[keys[2]], 1, 16),
    );
  }

  void validate(List<P2pFile> files, int recipients) {
    boundedInt(files.length, 1, maxFiles);
    boundedInt(recipients, 1, maxRecipients);
    for (final file in files) {
      boundedInt(file.size, 0, maxBytes);
    }
  }
}

class P2pFile {
  final String name, mime, hash;
  final int size;
  const P2pFile(this.name, this.mime, this.size, this.hash);
  factory P2pFile.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid file');
    }
    final name = value['name'], mime = value['mime'], hash = value['sha256'];
    if (name is! String ||
        name.isEmpty ||
        name.length > 255 ||
        name.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        mime is! String ||
        mime.isEmpty ||
        mime.length > 200 ||
        mime.contains(RegExp(r'[\r\n]')) ||
        hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('Invalid file metadata');
    }
    return P2pFile(
      name,
      mime,
      boundedInt(value['size'], 0, 100000000000),
      hash,
    );
  }
  String get saveName =>
      name.replaceAll(RegExp(r'[/\\:]'), '_').replaceAll(RegExp(r'^\.+$'), '_');
  Map<String, dynamic> toJson() => {
    'name': name,
    'mime': mime,
    'size': size,
    'sha256': hash,
  };
}

List<P2pFile> parseP2pFiles(Object? value) {
  if (value is! List ||
      value.isEmpty ||
      value.length > 100 ||
      utf8.encode(jsonEncode(value)).length > p2pManifestBytes) {
    throw const FormatException('Invalid manifest');
  }
  return value.map(P2pFile.fromJson).toList(growable: false);
}

String p2pPercent(int confirmed, int size, {bool verified = false}) {
  if (size < 0 || confirmed < 0 || confirmed > size) {
    throw RangeError('Invalid progress');
  }
  final hundredths = size == 0
      ? (verified ? 10000 : 0)
      : ((BigInt.from(confirmed) * BigInt.from(10000)) ~/ BigInt.from(size))
            .toInt();
  return '${hundredths ~/ 100},${(hundredths % 100).toString().padLeft(2, '0')}%';
}

enum P2pRoute { unknown, direct, relay }

P2pRoute p2pRouteFromStats(List<Map<String, dynamic>> stats) {
  final byId = {for (final stat in stats) stat['id']: stat};
  final selected = stats.where(
    (s) => s['type'] == 'transport' && s['selectedCandidatePairId'] != null,
  );
  final pairs = selected.isNotEmpty
      ? selected
            .map((s) => byId[s['selectedCandidatePairId']])
            .whereType<Map<String, dynamic>>()
      : stats.where(
          (s) =>
              s['type'] == 'candidate-pair' &&
              (s['selected'] == true ||
                  (s['nominated'] == true && s['state'] == 'succeeded')),
        );
  for (final pair in pairs) {
    final local = byId[pair['localCandidateId']],
        remote = byId[pair['remoteCandidateId']];
    if (local?['candidateType'] == 'relay' ||
        remote?['candidateType'] == 'relay') {
      return P2pRoute.relay;
    }
    if (local?['candidateType'] != null && remote?['candidateType'] != null) {
      return P2pRoute.direct;
    }
  }
  return P2pRoute.unknown;
}

Uint8List p2pFrame(int file, int offset, Uint8List payload) {
  boundedInt(file, 0, 99);
  boundedInt(offset, 0, 100000000000);
  boundedInt(payload.length, 1, p2pFrameBytes - p2pHeaderBytes);
  final result = Uint8List(p2pHeaderBytes + payload.length);
  final header = ByteData.sublistView(result);
  header.setUint32(0, file);
  header.setUint32(4, offset ~/ 4294967296);
  header.setUint32(8, offset % 4294967296);
  header.setUint32(12, payload.length);
  result.setRange(p2pHeaderBytes, result.length, payload);
  return result;
}

({int file, int offset, Uint8List bytes}) parseP2pFrame(Uint8List data) {
  if (data.length <= p2pHeaderBytes || data.length > p2pFrameBytes) {
    throw const FormatException('Invalid frame');
  }
  final header = ByteData.sublistView(data);
  final file = boundedInt(header.getUint32(0), 0, 99);
  final offset = boundedInt(
    header.getUint32(4) * 4294967296 + header.getUint32(8),
    0,
    100000000000,
  );
  if (header.getUint32(12) != data.length - p2pHeaderBytes) {
    throw const FormatException('Invalid frame length');
  }
  return (
    file: file,
    offset: offset,
    bytes: Uint8List.sublistView(data, p2pHeaderBytes),
  );
}

class P2pHash implements Sink<Digest> {
  late final ByteConversionSink input = sha256.startChunkedConversion(this);
  Digest? _digest;
  @override
  void add(Digest data) {
    _digest = data;
  }

  @override
  void close() {}
  String finish() {
    input.close();
    return _digest!.toString();
  }
}

/// Three-second useful throughput, based on monotonically acknowledged bytes.
class P2pSpeed {
  final _samples = <({int at, int bytes})>[];
  int _total = 0;
  void record(int total, int nowMs) {
    if (total < _total) throw RangeError('Progress moved backwards');
    _samples.add((at: nowMs, bytes: total - _total));
    _total = total;
    _prune(nowMs);
  }

  void _prune(int nowMs) => _samples.removeWhere((s) => s.at <= nowMs - 3000);
  double perSecond(int nowMs) {
    _prune(nowMs);
    return _samples.fold<int>(0, (sum, s) => sum + s.bytes) / 3;
  }
}
