import 'message_media_cache.dart';
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
  late Future<Uint8List> image = cachedLoad();
  Future<Uint8List> cachedLoad() =>
      MessageMediaCache.of(widget.client).loadAvatar(widget.url, load);
  Future<Uint8List> load() async {
    final client = widget.client, avatar = widget.url;
    if (avatar.scheme != 'mxc') {
      throw const FormatException('Invalid avatar');
    }
    final url = await avatar.getDownloadUri(client, skipScanner: true);
    if (url.origin != client.homeserver!.origin) {
      throw const FormatException('Untrusted avatar');
    }
    final request = http.Request('GET', url)..followRedirects = false;
    request.headers['authorization'] = 'Bearer ${client.accessToken}';
    final response = await client.httpClient
        .send(request)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw const FormatException('Invalid avatar response');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final block in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      if (bytes.length + block.length > 10485760) {
        throw const FormatException('Invalid avatar response');
      }
      bytes.add(block);
    }
    return bytes.takeBytes();
  }

  @override
  void didUpdateWidget(AvatarImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.client != widget.client) {
      image = cachedLoad();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    key: ValueKey((widget.client, widget.url)),
    initialData: MessageMediaCache.of(widget.client).avatar(widget.url),
    future: image,
    builder: (_, snapshot) => snapshot.hasData
        ? Image.memory(
            snapshot.data!,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            cacheWidth: 180,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => widget.fallback,
          )
        : widget.fallback,
  );
}
