import 'dart:convert';

/// Server time controls admission; the UI uses elapsed time only for display.
class LiveStreamSnapshot {
  final String id, owner, title, description, state, ownerDevice, generation;
  final int revision, viewers, keyEpoch;
  final bool comments;
  final DateTime startedAt, endsAt, serverNow;
  final List<String>? viewerUsers;
  const LiveStreamSnapshot._(
    this.id,
    this.owner,
    this.title,
    this.description,
    this.state,
    this.revision,
    this.viewers,
    this.comments,
    this.startedAt,
    this.endsAt,
    this.serverNow,
    this.viewerUsers,
    this.ownerDevice,
    this.generation,
    this.keyEpoch,
  );

  factory LiveStreamSnapshot.parse(Map<String, dynamic> value) {
    String text(String key, int maximum, {bool empty = false}) {
      final raw = value[key];
      if (raw is! String ||
          (!empty && raw.isEmpty) ||
          raw.runes.length > maximum) {
        throw const FormatException('stream text');
      }
      return raw;
    }

    int integer(String key, int minimum, int maximum) {
      final raw = value[key];
      if (raw is! int || raw < minimum || raw > maximum) {
        throw const FormatException('stream integer');
      }
      return raw;
    }

    DateTime instant(String key) {
      final raw = value[key];
      if (raw is! num || !raw.isFinite || raw < 0 || raw > 8640000000000) {
        throw const FormatException('stream time');
      }
      return DateTime.fromMillisecondsSinceEpoch(
        (raw * 1000).round(),
        isUtc: true,
      );
    }

    final state = text('state', 32);
    if (!{'live', 'paused', 'reconnecting'}.contains(state) ||
        value['comments'] is! bool) {
      throw const FormatException('stream state');
    }
    final viewers = integer('viewers', 0, 10);
    final rawUsers = value['viewer_users'];
    List<String>? users;
    if (rawUsers != null) {
      if (rawUsers is! List ||
          rawUsers.length != viewers ||
          rawUsers.any((v) => v is! String || v.isEmpty || v.length > 255) ||
          rawUsers.toSet().length != rawUsers.length) {
        throw const FormatException('stream viewers');
      }
      users = List<String>.unmodifiable(rawUsers.cast<String>());
    }
    final start = instant('started_at'),
        end = instant('ends_at'),
        now = instant('server_now');
    if (!end.isAfter(start) || now.isBefore(start)) {
      throw const FormatException('stream deadline');
    }
    return LiveStreamSnapshot._(
      text('id', 128),
      text('owner', 255),
      text('title', 120),
      text('description', 2000, empty: true),
      state,
      integer('revision', 1, 9007199254740991),
      viewers,
      value['comments'] as bool,
      start,
      end,
      now,
      users,
      text('owner_device', 255),
      text('generation', 128),
      integer('key_epoch', 1, 9007199254740991),
    );
  }

  Duration remaining([Duration elapsed = Duration.zero]) {
    final left = endsAt.difference(serverNow.add(elapsed));
    return left.isNegative ? Duration.zero : left;
  }

  double progress([Duration elapsed = Duration.zero]) =>
      (serverNow.add(elapsed).difference(startedAt).inMilliseconds /
              endsAt.difference(startedAt).inMilliseconds)
          .clamp(0, 1)
          .toDouble();
}

class LiveStreamEncryptedComment {
  final int sequence;
  final String id, author, device;
  final List<int> ciphertext;
  LiveStreamEncryptedComment._(
    this.sequence,
    this.id,
    this.author,
    this.device,
    this.ciphertext,
  );

  factory LiveStreamEncryptedComment.parse(Map<String, dynamic> value) {
    String text(String key, int maximum) {
      final raw = value[key];
      if (raw is! String || raw.isEmpty || raw.length > maximum)
        throw const FormatException('stream message metadata');
      return raw;
    }

    final sequence = value['sequence'];
    if (sequence is! int || sequence < 1 || sequence > 9007199254740991)
      throw const FormatException('stream sequence');
    final encoded = text('ciphertext', 10924);
    final bytes = base64Decode(encoded);
    if (bytes.isEmpty || bytes.length > 8192 || base64Encode(bytes) != encoded)
      throw const FormatException('stream ciphertext');
    return LiveStreamEncryptedComment._(
      sequence,
      text('id', 128),
      text('author', 255),
      text('device', 255),
      bytes,
    );
  }

  int? get epoch {
    try {
      final header = jsonDecode(utf8.decode(ciphertext));
      if (header is Map && header['epoch'] is int && header['epoch'] > 0)
        return header['epoch'] as int;
    } catch (_) {
      /* An invalid ciphertext is shown as an unverified placeholder. */
    }
    return null;
  }
}
