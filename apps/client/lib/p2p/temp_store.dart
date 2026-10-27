import 'dart:typed_data';
import 'package:matrix/matrix.dart';
import '../local_store.dart';
import 'protocol.dart';

/// The journal only owns disposable blobs. It never restores a network transfer.
class P2pTempStore {
  final Client client;
  static const _key = 'dev.voicechat.local.p2p.temporary';
  final Set<String> _ids = {};
  Future<void> _writes = Future.value();
  P2pTempStore(this.client);
  Future<void> open() async {
    final data = (await client.database.getAccountData())[_key]?.content['ids'];
    if (data != null &&
        (data is! List ||
            data.length > 10000 ||
            data.any((id) => !validP2pId(id)))) {
      throw const FormatException('Invalid temporary transfer registry');
    }
    for (final id in (data as List? ?? []).cast<String>()) {
      await deleteP2pBlobs(client.clientName, id);
    }
    await _save();
  }

  Future<void> _save() {
    final snapshot = _ids.toList();
    return _writes = _writes
        .catchError((Object _) {})
        .then((_) => client.database.storeAccountData(_key, {'ids': snapshot}));
  }

  Future<void> register(String id) async {
    if (!validP2pId(id)) throw ArgumentError('Invalid transfer');
    _ids.add(id);
    await _save();
  }

  Future<void> put(String id, int file, int block, Uint8List data) {
    if (!_ids.contains(id) || data.length > p2pBlockBytes) {
      throw StateError('Closed transfer');
    }
    return writeP2pBlob(client.clientName, 'p2p/$id/$file/$block', data);
  }

  Stream<Uint8List> range(
    String id,
    int file,
    int size,
    int from,
    int to,
  ) async* {
    if (!_ids.contains(id) || from < 0 || from > to || to > size) {
      throw RangeError('Invalid range');
    }
    while (from < to) {
      final block = from ~/ p2pBlockBytes;
      final bytes = await readP2pBlob(
        client.clientName,
        'p2p/$id/$file/$block',
      );
      final expected = (size - block * p2pBlockBytes).clamp(0, p2pBlockBytes);
      if (bytes == null || bytes.length != expected) {
        throw StateError('Temporary file unavailable');
      }
      final offset = from % p2pBlockBytes;
      final count = (to - from).clamp(0, bytes.length - offset);
      yield Uint8List.sublistView(bytes, offset, offset + count);
      from += count;
    }
  }

  Future<void> remove(String id) async {
    if (!_ids.contains(id)) return;
    await deleteP2pBlobs(client.clientName, id);
    _ids.remove(id);
    await _save();
  }

  Future<void> close() async {
    for (final id in _ids.toList()) {
      await remove(id);
    }
    await _writes;
  }
}
