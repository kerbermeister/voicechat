/// Optional at-rest codec. Record context must be authenticated by the codec.
abstract interface class DatabaseCodec {
  Future<Object?> encode(String store, String key, Object? value);
  Future<Object?> decode(String store, String key, Object? value);
}

/// Authentication failure must not trigger destructive session recovery.
class DatabaseIntegrityException implements Exception {
  const DatabaseIntegrityException();
  @override
  String toString() => 'Encrypted database integrity check failed';
}
