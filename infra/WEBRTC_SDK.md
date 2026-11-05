# Native call synchronization SDK

**Not release-qualified (2026-11-05).** Native app channels remain62. SDK4's
130ms default was rejected by real SDK3 encrypted-SFU precursors (113.640ms and
speech regression); its binary builds were cancelled and its45/9 C++ proof is
retained. SDK3 fixed70 passes SFU but fails P2P recovery89.317ms. First SDK3
fixed90 P2P/SFU precursors pass, but its second P2P pair fails pause speech by
0.007431STOI. SDK5 C++46/46 plus10 negative regressions pass at run41955022535;
its binary builds and full native media series remain required.

The VoiceChat fork pins WebRTC150.7871.04, official builder/depot_tools and every
original/patched source file in `webrtc-sdk.json`. The12-file vc5 patch retains
vc3's bounded effective render calculation, stale synchronization-floor cleanup
and80ms cap on synchronization-added audio buffering. It also reports the
remaining video render wait from the latest packet's receive time. Relative
network delay is already measured from packet arrival; using only the nominal
buffer ignored shifts in the RTP-to-local-clock fit after jitter. Render times
in the past, low-latency rendering and absent RTP fits report zero added wait.
Natural NetEq/device buffers, codecs, crypto and certificate validation remain.

Native initialization supplies `WebRTC-ForcePlayoutDelay/min_ms:90,max_ms:90/`
only when the caller has not specified that field-trial key. Explicit0/90/130ms,
other trials and native invalid-input validation remain. This key affects the
receiver; the pinned RTP sender uses separate WebRTC-ForceSendPlayoutDelay.
No outgoing delay hint is forced. Hosted flutter_webrtc and its public API are
unchanged. ObjC factory configuration and Java initialization-options builder
apply the default before their factory/transport is created; no factory resets.

The configuration has9 cases per platform. macOS compiles the actual method/
helper using Foundation, then checks the compiled SDK policy. Android invokes
the actual AAR builder on the JVM with an inert Context; no device/native API
runs. These are configuration checks, not media/device acceptance. CI requires
46 actual C++ tests,10 negative regressions and zero skips. The new test covers
arrival later/earlier than the extrapolated clock, overdue frames, absent clock
fit and low-latency rendering. Every source/toolchain receipt must match; older
SDK proof cannot qualify vc5. Mac arm64 and Android3ABIs build after that gate.

Use an isolated runner with at least18GB free, Python3.11+ and the official tools:

```sh
git clone https://github.com/webrtc-sdk/webrtc-build.git sdk-builder
git -C sdk-builder checkout 717ec1dc5a94389d691e09cccaf3d7b3364fb4b7
python3 infra/build_webrtc_sdk.py test --builder sdk-builder/build --work /tmp/vc-sdk-test --output /tmp/vc-sdk-tests
```

Use fresh work/output paths. Substitute `macos` or `android` for `test` on the
appropriate runner. The workflow selects Xcode26.0 on macOS and installs Linux
prerequisites. SDK artifact names come from the pinned manifest. Packaging
includes source/hash receipts and generated third-party notices, including in
framework resources and Android assets so application packaging retains them.
The workflow has read-only permissions and no release secrets. Dependency
prereleases are not application updates; archives stay immutable.

Binary pins belong in `webrtc-sdk-artifacts.json`. The Android helper checks AAR
hash, size and local Maven metadata on download/reuse. Gradle forces both consumers
to that module. CocoaPods overrides only WebRTC-SDK through the checksum-pinned
archive. When a same-version external podspec changes, `pod install` can reuse
its old sandbox spec: use targeted `pod update WebRTC-SDK --no-repo-update`, verify
the generated lock and the actual framework UUID. Never accept an edited lock
as proof that a new framework was installed. Keep the existing SPM-disabled path.

Native P2P/SFU calls, actual encrypted-content controls, ordinary-voice latency
and matched speech must pass before app publication. Raw/source-corrected A/V and
added voice delay stay within80ms; STOI margin0.005, level tolerance0.15dB and at
least4 matched speech clips per phase remain unchanged. Missing evidence does
not qualify. Physical devices and acoustic/display latency are separate evidence.
The sole user acceptance entry is [UA-08.C06](../docs/user-acceptance.md).

Failed trials and all policy comparisons remain in the technical iteration
journal. Native90 is a candidate plus a new render-delay correction, not the
previous rejected fixed90/split-stream wrapper. It retains shared P2P streams.
Fresh compiled vc5 SDKs, full native P2P/SFU/voice/speech/crypto/mirror/delay series
and signed app updates are required. Public Mac/Android channels remain62.
