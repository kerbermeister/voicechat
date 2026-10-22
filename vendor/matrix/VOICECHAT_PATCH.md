# Local patch: Matrix Dart SDK 14.2.0

Source: https://pub.dev/packages/matrix/versions/14.2.0
Upstream: https://github.com/famedly/matrix-dart-sdk
Pub archive SHA-256: `efe7b5a456957e1292fa331c531abba89bb4867b0f0ba78642a51497e34ba3b1`.

The `lib/`, `pubspec.yaml`, README and LICENSE are vendored from that package. The original AGPL-3.0-or-later license and copyright notices are retained. The app uses a path dependency so release builds and CI cannot silently omit the security patch. Upstream dev tools/tests are not copied.

Changes relative to upstream:

- `database_codec.dart`: optional asynchronous record codec and a distinct integrity error.
- `matrix_sdk_database.dart`, `sqflite_box.dart`, `matrix.dart`: forward/export the codec; native SQLCipher behavior is unchanged.
- `indexeddb_box.dart`: authenticate/decrypt all value reads and encrypt all value writes before starting IndexedDB transactions. Cached values stay in memory. Await write commits; handle nested transactions, aborts and invalidate caches after transaction failures. Prevent an asynchronous read/decode from overwriting a newer cached mutation; replay cache mutations in write order for delete/clear followed by put.
- `client.dart`: an authenticated storage integrity failure must not trigger the SDK's destructive initialization recovery. The app closes the failed client and preserves the store.
- `client.dart`: an empty encrypted recipient list is a no-op, instead of encrypting an empty map and making a needless HTTP request. `room.dart`: preserve full member events/IDs when fetching participants, and do not rewrite unchanged membership on each fresh authorization check. Server membership and device queries are still performed; actual join/leave changes still update the cache. Regression checks: `apps/client/test/authorization_work_test.dart`.

- `voip/voip.dart`: honor a call ended by the delegate during listener registration, before creating the incoming peer connection. Fetch TURN credentials per call instead of caching expiring credentials indefinitely.
- `voip/call_session.dart`: defer incoming direct-call microphone capture until `answer()`. Ringing alone must never open the microphone. The Android/web direct-call scenario asserts this before acceptance.
- `key_verification.dart`: expose the keys actually authenticated by SAS/QR so the application can pin the exact proven device instead of treating a pre-existing TOFU flag as evidence. Redact verification payloads from logs. Cancellation fences further processing before waiting for its network message, and periodic cleanup cannot extend the original ten-minute deadline. No change to the SAS/QR cryptographic calculations or message formats; regression checks are in `apps/client/test/device_verification_test.dart`.
- `key_verification.dart`: validate both QR keys against the selected mode/user, not only the second key. Reject malformed transaction lengths, unknown modes/versions, foreign requests, blocked keys and completed requests before granting trust. The standard Matrix binary format is unchanged; boundary checks are in `apps/client/test/device_qr_test.dart`.

No changes to Olm, Megolm, signatures, SAS calculations or wire protocols. QR input validation is corrected as described above. Codec implementation and Web Crypto are in the application. Record keys and store names remain visible; values are encrypted.

Before updating the dependency, compare these files against the pinned upstream, reapply only required changes, then run the browser vault tests, Android storage test and full Android/web E2EE scenario. Prefer removing this patch when upstream offers an equivalent supported codec interface.
