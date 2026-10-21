import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'picked_file.dart';

class ChunkedFile {
  final Client client;
  final Map<String, dynamic> content;
  final int size;
  final List<Map<String, dynamic>> parts;
  final _cache = <int, Future<Uint8List>>{};
  String get name => content['body'] as String;
  String get mime => content['mime'] as String;
  bool get videoNote => content['video_note'] == true;
  ChunkedFile(this.client, this.content)
    : size = content['size'] as int,
      parts = (content['parts'] as List)
          .map((p) => Map<String, dynamic>.from(p as Map))
          .toList() {
    if (size < 1 ||
        size > 314572800 ||
        parts.length != (size + fileChunkBytes - 1) ~/ fileChunkBytes ||
        content['body'] is! String ||
        name.isEmpty ||
        name.length > 1024 ||
        content['mime'] is! String ||
        mime.length > 200 ||
        mime.contains(RegExp(r'[\r\n]'))) {
      throw const FormatException('Invalid file manifest');
    }
    if ((content['caption'] != null &&
            (content['caption'] is! String ||
                (content['caption'] as String).length > 16000)) ||
        (content['video_note'] != null && content['video_note'] is! bool) ||
        (content['duration'] != null &&
            (content['duration'] is! int ||
                (content['duration'] as int) < 1 ||
                (content['duration'] as int) > 600000))) {
      throw const FormatException('Invalid file metadata');
    }
    for (var i = 0; i < parts.length; i++) {
      final expected = i == parts.length - 1
          ? size - i * fileChunkBytes
          : fileChunkBytes;
      final file = parts[i]['file'];
      if (parts[i]['size'] != expected ||
          file is! Map ||
          file['v'] != 'v2' ||
          file['key'] is! Map ||
          file['key']['k'] is! String ||
          file['iv'] is! String ||
          file['hashes'] is! Map ||
          file['hashes']['sha256'] is! String ||
          file['url'] is! String ||
          Uri.tryParse(file['url'])?.scheme != 'mxc') {
        throw const FormatException('Invalid encrypted file part');
      }
    }
  }
  Future<Uint8List> part(int index) {
    if (index < 0 || index >= parts.length) {
      throw RangeError.index(index, parts);
    }
    if (!_cache.containsKey(index) && _cache.length >= 2) {
      _cache.remove(_cache.keys.first);
    }
    return _cache.putIfAbsent(
      index,
      () => _load(index).catchError((Object error) {
        _cache.remove(index);
        throw error;
      }),
    );
  }

  Future<Uint8List> _load(int index) async {
    final file = parts[index]['file'] as Map;
    final uri = await Uri.parse(
      file['url'] as String,
    ).getDownloadUri(client, skipScanner: true);
    if (uri.origin != client.homeserver!.origin) {
      throw const FormatException('Untrusted media origin');
    }
    final request = http.Request('GET', uri)..followRedirects = false;
    request.headers['authorization'] = 'Bearer ${client.accessToken}';
    final response = await client.httpClient
        .send(request)
        .timeout(const Duration(seconds: 30));
    final expected = parts[index]['size'] as int;
    final bytes = BytesBuilder(copy: false);
    await for (final block in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      if (response.statusCode != 200 ||
          bytes.length + block.length > expected) {
        throw const FormatException('Invalid media response');
      }
      bytes.add(block);
    }
    if (response.statusCode != 200 || bytes.length != expected) {
      throw const FormatException('Incomplete media part');
    }
    final plain = await client.nativeImplementations.decryptFile(
      EncryptedFile(
        data: bytes.takeBytes(),
        k: file['key']['k'] as String,
        iv: file['iv'] as String,
        sha256: file['hashes']['sha256'] as String,
      ),
    );
    if (plain == null || plain.length != expected) {
      throw const FormatException('File integrity check failed');
    }
    return plain;
  }

  Stream<Uint8List> range(int start, int end) async* {
    if (start < 0 || end > size || start >= end) {
      throw RangeError('Invalid file range');
    }
    while (start < end) {
      final index = start ~/ fileChunkBytes;
      final bytes = await part(index);
      final offset = start % fileChunkBytes;
      final count = (end - start).clamp(0, bytes.length - offset);
      yield Uint8List.sublistView(bytes, offset, offset + count);
      start += count;
    }
  }

  void clear() => _cache.clear();
}
