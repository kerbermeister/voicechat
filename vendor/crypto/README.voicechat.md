# crypto 3.0.7: web hashes beyond 4 GiB

Upstream: https://github.com/dart-lang/core/tree/main/pkgs/crypto
BSD license retained in LICENSE and source headers. Imported from the locked
3.0.7 package. Only algorithm change: `lib/src/hash_sink.dart` rounds the final
length with integer division/multiplication instead of bitwise AND. dart2js
bitwise operators discard high bits, producing negative padding lengths for
5,000,000,000-byte inputs. SHA compression and length encoding are unchanged.

Validation: normal project crypto regressions plus the release P2P harness hashes
and transfers 5 GB, comparing to an independent Python hashlib reference.
Remove this override when a pinned upstream release includes and passes this fix.
