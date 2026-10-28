// Run only after MatrixProbe initializes the real native crypto library.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/chunked_file.dart';
import '../test/route_io_test.dart' show canonical, serve, endpoint, network;

class DownloadClient implements Client {
  @override
  final http.Client httpClient;
  DownloadClient(this.httpClient);
  @override
  Uri get homeserver => canonical;
  @override
  String get accessToken => 'test-only-token';
  @override
  NativeImplementations get nativeImplementations =>
      NativeImplementations.dummy;
  @override
  Future<bool> authenticatedMediaSupported() async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> checkEncryptedFileRecovery() async {
  final plain = Uint8List.fromList(List.generate(4096, (i) => i % 251));
  final encrypted = await MatrixFile(bytes: plain, name: 'test.bin').encrypt();
  var bRequests = 0, cRequests = 0;
  var corrupt = true;
  void checkRequest(HttpRequest request) {
    expect(
      request.uri.path,
      '/_matrix/client/v1/media/download/stable.test/object',
    );
    expect(request.headers.value('authorization'), 'Bearer test-only-token');
  }

  final b = await serve((request) async {
    checkRequest(request);
    bRequests++;
    final socket = await request.response.detachSocket(writeHeaders: false);
    socket.add(
      ascii.encode(
        'HTTP/1.1 200 OK\r\nContent-Length: ${encrypted.data.length}\r\nConnection: close\r\n\r\n',
      ),
    );
    socket.add(encrypted.data.sublist(0, 100));
    await socket.flush();
    await socket.close();
  });
  final c = await serve((request) async {
    checkRequest(request);
    cRequests++;
    final data = Uint8List.fromList(encrypted.data);
    if (corrupt) data[0] ^= 1;
    request.response.contentLength = data.length;
    request.response.add(data);
    await request.response.close();
  });
  final routes = network(b, c);
  final file = ChunkedFile(DownloadClient(routes), {
    'body': 'test.bin',
    'mime': 'application/octet-stream',
    'size': plain.length,
    'parts': [
      {
        'size': plain.length,
        'file': {
          'v': 'v2',
          'url': 'mxc://stable.test/object',
          'key': {'k': encrypted.k},
          'iv': encrypted.iv,
          'hashes': {'sha256': encrypted.sha256},
        },
      },
    ],
  });
  await expectLater(file.part(0), throwsA(isA<http.ClientException>()));
  expect(bRequests, 1);
  expect(cRequests, 0);
  routes.select(endpoint(c));
  await expectLater(file.part(0), throwsA(isA<FormatException>()));
  expect(cRequests, 1);
  corrupt = false;
  expect(await file.part(0), plain);
  expect(await file.part(0), plain);
  expect(cRequests, 2); // Only verified plaintext enters the part cache.
  expect(bRequests, 1);
}
