import 'package:matrix/matrix.dart';

/// Local encrypted account storage; no statistics are published to other people.
class ReactionUsage {
  ReactionUsage(this.database);
  final DatabaseApi database;
  static const storageKey = 'dev.voicechat.local.reaction_usage';
  final counts = <String, int>{};
  final _recorded = <String>[];
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  Future<void> load() =>
      _loading ??= _load().catchError((Object error, StackTrace stack) {
        _loading = null;
        Error.throwWithStackTrace(error, stack);
      });
  Future<void> _load() async {
    final data = (await database.getAccountData())[storageKey];
    final values = data?.content['counts'];
    if (values is Map) {
      for (final entry in values.entries.take(4096)) {
        if (entry.key is String &&
            (entry.key as String).length <= 64 &&
            entry.value is int &&
            entry.value > 0) {
          counts[entry.key as String] = entry.value as int;
        }
      }
    }
    final recorded = data?.content['recorded'];
    if (recorded is List) {
      _recorded.addAll(recorded.whereType<String>().take(512));
    }
  }

  List<String> get frequent {
    final sorted = counts.entries.toList()
      ..sort((a, b) {
        final frequency = b.value.compareTo(a.value);
        return frequency != 0 ? frequency : a.key.compareTo(b.key);
      });
    return sorted.take(12).map((entry) => entry.key).toList();
  }

  Future<void> record(String emoji, String transaction) =>
      _writes = _writes.catchError((Object _) {}).then((_) async {
        await load();
        if (emoji.isEmpty ||
            emoji.length > 64 ||
            _recorded.contains(transaction)) {
          return;
        }
        final next = {...counts, emoji: (counts[emoji] ?? 0) + 1};
        final recorded = [..._recorded, transaction];
        if (recorded.length > 512) recorded.removeAt(0);
        await database.storeAccountData(storageKey, {
          'counts': next,
          'recorded': recorded,
        });
        counts
          ..clear()
          ..addAll(next);
        _recorded
          ..clear()
          ..addAll(recorded);
      });
}
