# Bounded A/V synchronization SDK

This candidate retains WebRTC SDK 150.7871.04 and its security fixes. The seven-file
patch makes rendering and A/V synchronization use the same effective current
video delay, including the low-latency path and negotiated bounds. The unbounded
jitter estimate remains available to the video frame-buffer reset guard. Native
factory defaults and adaptive/audio-device buffering are preserved. Audio
DSP, codecs, cryptors and certificate validation are unchanged.

`webrtc-sdk.json` pins the SDK source, official builder, depot_tools, patch and all
seven source files before/after patching. `build_webrtc_sdk.py` rejects unexpected inputs.
The CI workflow first proves that eight regression tests fail with the original
getter/synchronizer behavior, then runs all 43 timing and synchronization tests.
The synchronizer releases only its minimum-delay floors when either RTP stream
has been absent for two seconds, when stream information disappears, or when
the pair changes. Destruction releases the audio floor. Receive buffers are not
flushed; device/base latency and negotiated video bounds remain intact. Only after that gate can
it build the published macOS client’s arm64 framework and an Android AAR with the three supported
application ABIs. Each artifact includes a SHA-256 build receipt.

Run on an isolated machine with at least 18 GB free (more may be required by the
Chromium dependency checkout), Python 3.11+, and the official platform toolchain:

```sh
git clone https://github.com/webrtc-sdk/webrtc-build.git sdk-builder
git -C sdk-builder checkout 717ec1dc5a94389d691e09cccaf3d7b3364fb4b7
python3 infra/build_webrtc_sdk.py test --builder sdk-builder/build --work /tmp/vc-sdk-test --output /tmp/vc-sdk-test-results
```

Use fresh work/output paths for each invocation. Substitute `macos` or `android`
for `test` on the appropriate CI runner. The workflow installs Linux build
prerequisites and selects Xcode 26.0 for macOS; the pinned WebRTC DEPS supplies
its remaining toolchain. The workflow has read-only repository permissions and
neither accesses release secrets nor publishes an application update.

A successful SDK build is not release qualification. The application must still
pass actual native shared-stream P2P and LiveKit encrypted-media calls, speech
comparisons with an ordinary call, loss/recovery and lifecycle tests. Both raw
and source-corrected A/V offsets must remain within 80 ms. See the existing
[acceptance entry UA-08.C06](../docs/user-acceptance.md) for the open scope.

Source pins in `webrtc-sdk.json` are build inputs; checksums and URLs of accepted
SDK binaries belong in `webrtc-sdk-artifacts.json`. The Android helper verifies
the AAR before publishing it into the local Maven cache, and verifies cached
bytes on reuse. The macOS Podfile overrides only the WebRTC-SDK pod with the checksum-pinned
archive; Android uses Gradle's module resolution to select the same custom SDK
for both existing dependents. flutter_webrtc remains the hosted package from the
unchanged pubspec.lock, without a copied wrapper or native-factory changes.
The application's existing enable-swift-package-manager:false setting is required
for this macOS delivery path; an unconfigured SwiftPM switch is not supported.
The SDK workflow automatically runs only when its build script, source manifest
or C++ patch changes. Documentation, artifact delivery and app-only changes use
the existing SDK bytes; workflow/job changes can be checked with a manual run.


When only packaging/build orchestration changes, a manual `macos_only:true` run
can reuse `webrtc-timing-tests` from an explicitly chosen prior run through
`timing_tests_run`. The verifier requires the exact SDK/toolchain/source hashes,
all manifest-pinned passing test cases with no skips and every before-fix failure.
A changed source pin rejects reuse and requires a fresh C++ test run. The default
push path still runs native tests first. Compiled arm64 framework bytes and their
source/hash receipt are archived before packaging and uploaded even if a later
packaging step fails; application release qualification remains separate.

The vc1 dependency prerelease is rejected for application promotion: its first
Android P2P pilot reached 385.652 ms corrected recovery skew. vc2 adds stale-floor
recovery; its C++ and actual-call qualification are pending. The artifact manifest
still describes vc1 until new immutable vc2 binaries have been built and verified.
Do not publish client updates from this intermediate branch.
