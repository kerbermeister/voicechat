# Local patch: Matrix Dart SDK 14.2.0

Source: https://pub.dev/packages/matrix/versions/14.2.0
Upstream: https://github.com/famedly/matrix-dart-sdk
Pub archive SHA-256: `efe7b5a456957e1292fa331c531abba89bb4867b0f0ba78642a51497e34ba3b1`.

The `lib/`, `pubspec.yaml`, README and LICENSE are vendored from that package. The original AGPL-3.0-or-later license and copyright notices are retained. The app uses a path dependency so release builds and CI cannot silently omit the security patch. Upstream dev tools/tests are not copied.

Changes relative to upstream:

- `room.dart`: copy the requested temporary duration into the encrypted envelope for server-side expiry; body and attachments remain encrypted. Reply fallbacks reference a temporary message without copying its plaintext into a permanent reply. `temporary_message_test.dart` verifies the reply path; real Synapse expiry is checked separately.

- `client.dart`: apply count-only MSC2654 unread updates to in-memory rooms, including zero after reading on another device while muted. Persistence alone left the visible badge stale. Regression: `apps/client/test/unread_sync_test.dart`.

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

### Durable media publication guard (30 October 2026)

`Room.sendFileEvent` accepts an optional `beforeSend` asynchronous guard after
uploads and before `sendEvent`. VoiceChat checks its persisted one-minute outbox
window and current recipients there, so a slow completed upload cannot publish
an already-paused transaction or its file keys. Existing callers omit the guard
and retain their behavior. A request already sent to the homeserver cannot be
recalled by this hook. Covered by `apps/client/test/media_publication_guard_test.dart`.

### Restored edit aggregation (2 November 2026)

`Room.getTimeline` refreshes relation aggregation after initial decryption. Its
constructor indexed the encrypted placeholders before decryption, leaving edits
invisible until reopening even when their plaintext had been restored. Both
outer-relation variants are covered by `apps/client/test/restored_edit_test.dart`.
No encryption, trust or protocol change.

### Direct-call retries and incoming lifetime (2 November 2026)

`voip.dart` filters a private copy of each sync batch by room and call ID. An
expired invite drops only itself; delivery age and time spent dispatching earlier
events reduce the remaining lifetime. TURN/delegate setup consumes that same
budget; `CallSession` starts its capped remaining timer before RTC/SDP allocation.
A failed event is logged without discarding later independent events. Busy calls send the terminal `user_busy` event even when local UI callbacks are
suppressed. No automatic answering or new glare policy is introduced.

`call_session.dart` always removes the ended session and disposes its peer, while
preserving a newer call owner. Cancellation fences late peer creation and capture;
failed peer/remote SDP setup ends the session and propagates the error. Peer
ownership is detached before awaited disposal. Regression tests are
`call_event_batch_test.dart`, `call_retry_protocol_test.dart`,
`call_peer_lifecycle_test.dart` and `call_invite_lifetime_test.dart` in the client.
The app CallController keys direct calls by CallSession and scopes end-summary
deduplication by room/session, so a late callback cannot close a different room
sharing its call ID. These are protocol/timer fixtures, not physical phone or WAN acceptance. No
cryptographic algorithm, trust check, TURN credential policy or media preset is
weakened.

### Cancellable outgoing setup (2 November 2026)

`VoIP.inviteToCall` accepts an optional local `isCancelled` guard across TURN,
listener registration and outbound RTC setup. Cancelled or failed setup removes
only its own room/call routing and terminates an allocated session; it cannot
publish the abandoned session through the delegate. Existing callers may omit
the guard. The app registers the outgoing session before media awaits and races
its preparation against an explicit cancellation signal. Late platform results
still run the existing session cleanup. Regression coverage is in
`apps/client/test/call_start_cancellation_test.dart`. No wire protocol, media
preset, encryption or trust policy changes.

Room call signalling retries explicit `M_LIMIT_EXCEEDED` only, at most3 retries
and15s total scheduled wait. It preserves the encrypted envelope and transaction
ID, respects numeric Retry-After before legacy retry_after_ms, and fences
nonterminal retries after cancellation. Unknown header formats and excessive
waits fail without an early retry; ambiguous network failures are not replayed.
A local offer failure sends hangup so the peer can stop as well. Synapse limits
are unchanged. Twelve focused cases cover retry timing, cancellation, terminal
messages, encrypted payload/transaction reuse, bounds and non-retryable errors in
`apps/client/test/call_signaling_rate_limit_test.dart`.
