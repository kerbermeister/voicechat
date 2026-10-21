import 'package:web/web.dart' as web;

Future<void> openLink(Uri url) async {
  if (!['http', 'https'].contains(url.scheme) ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty) {
    throw const FormatException('Invalid link');
  }
  web.window.open(url.toString(), '_blank', 'noopener,noreferrer');
}
