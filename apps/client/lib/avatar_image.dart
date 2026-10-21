import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

class AvatarImage extends StatefulWidget {
  final Client client;
  final Uri url;
  final Widget fallback;
  const AvatarImage({
    super.key,
    required this.client,
    required this.url,
    required this.fallback,
  });
  @override
  State<AvatarImage> createState() => _AvatarImageState();
}

class _AvatarImageState extends State<AvatarImage> {
  late Future<Uint8List> image = load();
  Future<Uint8List> load() async {
    if (widget.url.scheme != 'mxc') {
      throw const FormatException('Invalid avatar');
    }
    final url = await widget.url.getDownloadUri(
      widget.client,
      skipScanner: true,
    );
    if (url.origin != widget.client.homeserver!.origin) {
      throw const FormatException('Untrusted avatar');
    }
    final request = http.Request('GET', url)..followRedirects = false;
    request.headers['authorization'] = 'Bearer ${widget.client.accessToken}';
    final response = await widget.client.httpClient
        .send(request)
        .timeout(const Duration(seconds: 15));
    final bytes = BytesBuilder(copy: false);
    await for (final block in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      if (response.statusCode != 200 ||
          bytes.length + block.length > 10485760) {
        throw const FormatException('Invalid avatar response');
      }
      bytes.add(block);
    }
    return bytes.takeBytes();
  }

  @override
  void didUpdateWidget(AvatarImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.client != widget.client) image = load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: image,
    builder: (_, snapshot) => snapshot.hasData
        ? Image.memory(
            snapshot.data!,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            cacheWidth: 180,
            errorBuilder: (_, _, _) => widget.fallback,
          )
        : widget.fallback,
  );
}
