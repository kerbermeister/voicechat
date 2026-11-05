# Native call synchronization SDK

The VoiceChat fork pins WebRTC150.7871.04, its official builder/depot_tools and
every original/patched source file in `webrtc-sdk.json`. The12-file vc4 patch
retains vc3's effective rendering-delay calculation, stale synchronization-floor
cleanup and80ms cap on synchronization-added audio buffering. Natural NetEq and
device buffering, codecs, crypto and certificate validation remain unchanged.

Native initialization now supplies `WebRTC-ForcePlayoutDelay/min_ms:130,max_ms:130/`
when the caller has not explicitly specified that field-trial key. This matches
the existing SFU policy. Explicit0/90/130ms settings and other field trials remain
intact; malformed input is left to the existing native validation. The hosted
flutter_webrtc wrapper and its public API are unchanged. The Objective-C factory
configuration and Android initialization-options builder apply this before their
factory/transport is created; no live factory is reinitialized.

The default is tested with9 cases per platform. macOS compiles and executes the
actual configuration method/helper using Foundation, then checks the compiled
SDK contains the policy. Android invokes the actual AAR initialization-options
builder on the JVM with an inert Context type; no device APIs/native library run.
These configuration checks do not claim media or physical-device acceptance.
The CI also requires45 actual C++ timing/synchronization tests,9 negative
regressions and zero skips. All source/toolchain pins must match the receipts;
SDK3 evidence cannot substitute for a fresh vc4 gate. The macOS arm64 SDK and all
three Android ABIs build only after the C++ gate.

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

Rejected evidence is retained: vc1 Android recovery416.472ms; vc2 Mac voice
+1165.610ms and continuous-RTP A/V1878.354ms. vc3 fixes accumulated voice delay
and passes speech, but adaptive Mac recovery still reaches99.364/100.681ms.
One vc3 diagnostic with native130ms passes A/V59.138ms clean/53.484ms recovery,
added voice<=23.166ms and speech. This motivates vc4's native defaults; it is not
vc4 qualification. Fresh compiled vc4 SDKs, full native media series and signed
application updates remain required. Public Mac/Android channels remain62.
