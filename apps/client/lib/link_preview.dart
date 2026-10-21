import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart';
import 'transport.dart';
import 'user_action_error.dart';

List<Uri> messageLinks(String text) =>
    RegExp(r'https?://[^\s<>]+', caseSensitive: false)
        .allMatches(text)
        .map(
          (m) =>
              Uri.tryParse(m[0]!.replaceFirst(RegExp(r'[.,!?:;)\]}]+$'), '')),
        )
        .whereType<Uri>()
        .where(
          (u) =>
              u.host.isNotEmpty &&
              u.userInfo.isEmpty &&
              u.toString().length <= 2048,
        )
        .toSet()
        .take(3)
        .toList();

String? youtubeVideoId(Uri url) {
  final host = url.host.toLowerCase();
  final parts = url.pathSegments;
  String? id;
  if (host == 'youtu.be' && parts.length == 1) {
    id = parts.single;
  } else if (const {
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'www.youtube-nocookie.com',
  }.contains(host)) {
    if (url.path == '/watch') {
      id = url.queryParameters['v'];
    } else if (parts.length == 2 &&
        const {'embed', 'shorts'}.contains(parts.first)) {
      id = parts.last;
    }
  }
  return id != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id) ? id : null;
}

class LinkPreview {
  final Uri url;
  final String title, description;
  final Uint8List? image;
  LinkPreview(this.url, this.title, this.description, this.image);
  factory LinkPreview.fromJson(Map<String, dynamic> data) {
    final urls = messageLinks(data['url'] is String ? data['url'] : '');
    if (urls.length != 1 ||
        urls.single.toString() != data['url'] ||
        data['title'] is! String ||
        (data['title'] as String).length > 256 ||
        data['description'] is! String ||
        (data['description'] as String).length > 512) {
      throw const FormatException('Invalid link preview');
    }
    Uint8List? image;
    final encoded = data['image'];
    if (encoded is String && encoded.length <= 262144) {
      try {
        final bytes = base64Decode(encoded);
        final info = img.findDecoderForData(bytes)?.startDecode(bytes);
        if (info != null &&
            info.width > 0 &&
            info.height > 0 &&
            info.width * info.height <= 4000000) {
          if (bytes.length <= 8192 && info.width <= 320 && info.height <= 320) {
            image = bytes;
          } else {
            final decoded = img.decodeImage(bytes);
            if (decoded == null) throw const FormatException('Invalid cover');
            final thumbnail = img.copyResize(
              decoded,
              width: info.width >= info.height ? 240 : null,
              height: info.height > info.width ? 180 : null,
            );
            final jpeg = img.encodeJpg(thumbnail, quality: 60);
            if (jpeg.length <= 8192) image = Uint8List.fromList(jpeg);
          }
        }
      } catch (_) {
        /* A broken cover does not hide the link. */
      }
    }
    return LinkPreview(urls.single, data['title'], data['description'], image);
  }
  Map<String, dynamic> toJson() => {
    'url': url.toString(),
    'title': title,
    'description': description,
    if (image != null) 'image': base64Encode(image!),
  };
  static Future<LinkPreview> fetch(
    Client client,
    String server,
    Uri url,
  ) async {
    final request = http.Request('POST', secureEndpoint('$server/link-preview'))
      ..headers.addAll({
        'Authorization': 'Bearer ${client.accessToken}',
        'Content-Type': 'application/json',
      })
      ..body = jsonEncode({'url': url.toString()});
    final response = await client.httpClient
        .send(request)
        .timeout(const Duration(seconds: 15));
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      if (response.statusCode != 200 || bytes.length + chunk.length > 524288) {
        throw UserActionError(
          'Не удалось получить превью. Ссылку можно отправить без него.',
        );
      }
      bytes.add(chunk);
    }
    if (response.statusCode != 200) {
      throw UserActionError('Превью временно недоступно.');
    }
    final result = LinkPreview.fromJson(
      jsonDecode(utf8.decode(bytes.takeBytes())) as Map<String, dynamic>,
    );
    if (result.url != url) throw const FormatException('Wrong preview URL');
    return result;
  }
}

List<LinkPreview> messagePreviews(String text, dynamic data) {
  if (data is! List || data.length > 3) return [];
  final urls = messageLinks(text);
  final result = <LinkPreview>[];
  for (final item in data) {
    if (item is! Map) continue;
    try {
      final preview = LinkPreview.fromJson(Map<String, dynamic>.from(item));
      if (urls.contains(preview.url)) result.add(preview);
    } catch (_) {
      /* Ignore malformed or obsolete previews. */
    }
  }
  return result;
}
