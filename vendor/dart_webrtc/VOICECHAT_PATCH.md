# Local dart_webrtc confirmation patch

Existing dependency1.8.2, not a version upgrade or a new package.
Source: https://pub.dev/packages/dart_webrtc/versions/1.8.2
Published archive SHA256: `078e3c431500147e5cc52b3c6ea41ed538f30c7720cc2467d2186c9251e62716`.
Runtime library, manifest and copyright/license notices retained from the
locked package; upstream dev examples/tests/tools omitted.

Runtime changes are limited to `lib/src/frame_cryptor_impl.dart` and the
extracted `worker_response.dart`. Analyzer options use the existing client
rules instead of an upstream dev-only lint dependency. Every existing key-provider response is checked for a worker error
before reporting success or updating state. Filters, five-second deadlines,
keys/ratchets/algorithms and the worker protocol are unchanged. WorkerResponse
is re-exported from its original internal module for existing consumers.
The actual worker remains the source from the pinned local LiveKit SDK.
Cryptor setup, enable, index, codec and disposal now await a matched successful
worker response with the same five-second deadline. State caches advance only
after confirmation; pending/finished disposal rejects subsequent commands.
Both ScriptTransform and encoded-stream constructors wait for setup ACK.
The LiveKit worker supplies ScriptTransform setup ACK/errors and rejects
commands for unknown tracks. It no longer acknowledges a failed stream setup.

Regression: apps/client/integration_test/key_provider_browser_fixture.dart
uses a real worker and deliberately removed providers; errors must propagate
for individual/shared keys, confirmed cache must remain, a fresh provider works.
This has no account, capture, SFU or media; separate media regressions remain
necessary before a release.
`key_epoch_browser_fixture.dart` additionally exercises real GCM slot changes,
late keys, disposed/unknown cryptor commands and removed-provider constructors.
Its loopback-only encoded-stream control does not affect production detection.
