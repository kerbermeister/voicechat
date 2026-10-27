import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:matrix/matrix.dart';

/// Account-scoped, bounded RAM only. No plaintext media is persisted on disk.
class MessageMediaCache {
  static final _clients = Expando<MessageMediaCache>();
  static MessageMediaCache of(Client client) =>
      _clients[client] ??= MessageMediaCache();
  static void clear(Client client) {
    _clients[client]?.dispose();
    _clients[client] = null;
  }

  final avatars = <Uri, Uint8List>{};
  final avatarLoads = <Uri, Future<Uint8List>>{};
  final _frames = <String, ui.Image>{};
  final _deadlines = <String, DateTime>{};
  final _expiryTimers = <String, Timer>{};
  int _avatarBytes = 0;
  bool _closed = false;

  Uint8List? avatar(Uri url) {
    final bytes = avatars.remove(url);
    if (bytes != null) avatars[url] = bytes;
    return bytes;
  }

  Future<Uint8List> loadAvatar(Uri url, Future<Uint8List> Function() load) {
    final bytes = avatar(url);
    if (bytes != null) return Future.value(bytes);
    return avatarLoads.putIfAbsent(url, () async {
      try {
        final bytes = await load();
        if (!_closed) {
          avatars[url] = bytes;
          _avatarBytes += bytes.length;
          while (avatars.length > 128 || _avatarBytes > 32 * 1024 * 1024) {
            _avatarBytes -= avatars.remove(avatars.keys.first)!.length;
          }
        }
        return bytes;
      } finally {
        avatarLoads.remove(url);
      }
    });
  }

  ui.Image? frame(String key) {
    final expiry = _deadlines[key];
    if (expiry != null && !expiry.isAfter(DateTime.now())) {
      removeFrame(key);
      return null;
    }
    final image = _frames.remove(key);
    if (image != null) _frames[key] = image;
    return image?.clone();
  }

  void removeFrame(String key) {
    _expiryTimers.remove(key)?.cancel();
    _deadlines.remove(key);
    _frames.remove(key)?.dispose();
  }

  void saveFrame(String key, ui.Image image, {DateTime? expiresAt}) {
    if (_closed) return;
    removeFrame(key);
    if (expiresAt != null) {
      final remaining = expiresAt.difference(DateTime.now());
      if (remaining <= Duration.zero) return;
      _deadlines[key] = expiresAt;
      _expiryTimers[key] = Timer(remaining, () => removeFrame(key));
    }
    _frames[key] = image.clone();
    while (_frames.length > 24) {
      removeFrame(_frames.keys.first);
    }
  }

  void dispose() {
    _closed = true;
    avatars.clear();
    avatarLoads.clear();
    _avatarBytes = 0;
    for (final key in _frames.keys.toList()) {
      removeFrame(key);
    }
  }
}
