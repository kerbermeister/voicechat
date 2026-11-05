# Bounded A/V synchronization SDK

The candidate retains WebRTC SDK150.7871.04 and its native factory defaults.
`webrtc-sdk.json` pins the SDK source, official builder, depot_tools, ten-file
patch and every modified file before/after patching. The unbounded video jitter
estimate remains available to the frame-buffer reset guard. Rendering and A/V
synchronization use the effective current video delay, including negotiated
bounds and the low-latency path.

The receiver releases stale synchronization minimum-delay floors after two
seconds without either RTP stream, when stream information disappears, and on
pair changes. Network pauses retain RTP/NTP estimates; reassignment recreates
them. Destruction releases only the audio floor because the video's playout
state may already have ended its lifetime. Receive packets are never flushed.

vc3 also limits synchronization-added audio buffering to80ms beyond the explicit
base target. It bounds the controller's retained state and output together.
Natural NetEq adaptation, device/base latency and the video delay needed for a
slow audio device remain independent. The optional internal constructor limit
leaves existing standalone StreamSynchronization callers unchanged; the real
RtpStreamsSynchronizer supplies the voice budget on configuration and reset.
Codecs, audio DSP, cryptors and certificate validation are unchanged.

The CI gate requires45 real C++ timing/synchronization tests, no skips, and nine
negative regressions against the original getter/synchronizer behavior. The
upstream GN test target declares the added dependencies as well as the small
isolated harness. The macOS arm64 framework and all three Android application
ABIs build only after that gate. Each archive includes a source/hash receipt.

Use an isolated runner with at least18GB free (the dependency checkout can need
more), Python3.11+ and the official platform toolchain:

```sh
git clone https://github.com/webrtc-sdk/webrtc-build.git sdk-builder
git -C sdk-builder checkout 717ec1dc5a94389d691e09cccaf3d7b3364fb4b7
python3 infra/build_webrtc_sdk.py test --builder sdk-builder/build --work /tmp/vc-sdk-test --output /tmp/vc-sdk-test-results
```

Use fresh work/output paths. Substitute `macos` or `android` for `test` on the
appropriate runner. The workflow installs Linux prerequisites and selects
Xcode26.0 on macOS; the pinned WebRTC DEPS supplies the remaining toolchain.
Only the build script, SDK manifest and C++ patch trigger automatic SDK builds.
A manual packaging retry can select `macos_only:true` and `timing_tests_run`;
reused evidence must match every SDK/toolchain/source pin and test requirement.
Changed source rejects reuse. Raw compiled frameworks and receipts are uploaded
even if packaging fails. The workflow uses read-only permissions and no release
secrets; SDK binaries are dependencies, not application updates.

Binary URLs/checksums belong in `webrtc-sdk-artifacts.json`. The Android helper
verifies the AAR before creating a local Maven repository and on reuse. Gradle
resolves both dependents to the same pinned module. CocoaPods overrides only
WebRTC-SDK using the checksum-pinned archive. flutter_webrtc remains the hosted
package from the unchanged pubspec.lock; no copied wrapper or fixed90 factory.
The existing `enable-swift-package-manager:false` setting remains required for
this macOS delivery path.

Native P2P/SFU calls, actual encrypted-content controls, ordinary-voice latency
and matched speech comparisons must pass before an application release. Raw
and source-corrected A/V offsets and added voice delay must stay within80ms;
STOI margin0.005, level tolerance0.15dB and minimum four matched speech clips per
phase remain unchanged. Missing evidence is a failure to qualify. The single
user acceptance entry is [UA-08.C06](../docs/user-acceptance.md).

Rejected dependencies remain immutable evidence: vc1 reached385.652/416.472ms
Android P2P recovery skew. vc2's Mac paired pilot passed A/V(~52ms), but voice
was1165.610ms later than ordinary voice during video pause; the audio queue had
built up to2s before reset. It also lacked enough matched pause speech clips.
Do not promote either dependency into application update feeds. vc3 passed the45/9 compiled gate; native media qualification is pending. The artifact manifest can describe the
last built rejected dependency until vc3 binaries are built and verified.
