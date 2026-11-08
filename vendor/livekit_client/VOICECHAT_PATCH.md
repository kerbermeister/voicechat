# Local LiveKit Flutter SDK patch

Source: https://pub.dev/packages/livekit_client/versions/2.13.2
Archive SHA256: `c63211bd5073b308417de2b048809c156f50cb5bda02713150478742be2a1bc1`.
Runtime Dart/web/plugin sources, package manifest and Apache-2.0 notices are
copied unchanged except for the files listed below. Upstream dev tools, tests
and example applications are omitted, as for the local Matrix SDK dependency.
The SDK version and exact `flutter_webrtc 1.6.3` dependency remain unchanged.

The original SDK creates a sender cryptor in `LocalTrackPublishedEvent`, after
negotiation has already permitted RTP. VoiceChat awaits cryptor creation, key
index and enable before each primary audio/video negotiation branch. Encodings
start inactive, including when another track/reconnect negotiates concurrently;
only after encryption is ready are the exact requested active flags restored.
A rejected key index, enabled state or sender activation fails publication. The
published handler reuses the cryptor instead of creating another disabled one.

- `lib/src/e2ee/e2ee_manager.dart`: pending/ready cryptor ownership by actual RTP
  endpoint, coalesced initialization, captured/replayed early state, and disposal
  that can await initialization and an already running close.
- `lib/src/support/rtc_identity_{native,web}.dart`: stable endpoint identity. Web
  transceiver getters create fresh Dart wrappers, so their JS endpoint is used.
- `lib/src/participant/local.dart`: awaited preparation and encoding activation
  before SDP; capture and unpublished sender rollback on encryption failure.
- `lib/src/core/engine.dart`, `lib/src/utils.dart`: inactive copies of initial
  encodings with all bitrate, frame rate, RID and scalability options preserved.
- `lib/src/core/room.dart`: release cryptors after RTP transports stop.
- `lib/src/core/room.dart`, `lib/src/managers/event.dart`: listen for the leave
  acknowledgement before sending it; cancel the waiter when sending fails.
- `lib/src/e2ee/key_provider.dart`: reject a false native key-installation result;
  expose a new sender slot/shared key only after successful installation. A
  rejected or delayed operation retains the last confirmed cache state.
- Public E2EEManager state/index setters also reject a false platform result.
  Enable changes are serialized and include publications arriving while a reply
  is pending, before committing the state used by subsequent cryptors. A failed
  batch is reported, not presented as an atomic rollback of already applied RPCs.
- `web/e2ee.worker.dart`, `web/e2ee.frame_cryptor.dart`: acknowledge actual
  ScriptTransform setup, propagate setup failures, and reject unknown-track
  state/index/codec commands. The existing encoded-stream setup response is
  preserved. Frame processing and key/ratchet algorithms are unchanged.

AES-GCM, ratchet/failure/discard settings, media keys, leases, trust checks,
server room rotation, codecs and membership protocol messages are unchanged. The AV1 guard
is preserved. No unencrypted recovery path is added.

Regression: `apps/client/integration_test/native_group_key_publication_test.dart`
with the isolated `apps/client/tool/check_sdk_key_publication.py` runner. It
forwards real native RPCs and delays only sender cryptor creation. An observer
without a decryptor must receive no decoded camera frames during that window.
The upstream failure is recorded in `docs/iterations/call-key-startup-52/`.
The delayed constructor probe also forces a concurrent real negotiation. A
simple await-only candidate failed this control with10 pre-cryptor frames. The
native failure fixture covers constructor/enable exceptions, an explicit false
enable result, and close during a pending native reply, for audio and video.
Re-run native/browser publication, failure/close and reconnect checks before
upgrading/removing this patch. Multi-codec backup senders and upstream's AV1
exception are unchanged; VoiceChat's encrypted call sources use VP8. A successful local build is not physical phone
acceptance or proof of acoustic A/V synchronization.
