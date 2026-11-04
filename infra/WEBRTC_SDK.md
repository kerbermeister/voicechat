# Bounded A/V synchronization SDK

This candidate retains WebRTC SDK 150.7871.04 and its security fixes. The four-file
patch bounds only the video delay reported to the A/V synchronizer. The unbounded
jitter estimate remains available to the video frame-buffer reset guard. Audio
DSP, codecs, cryptors and certificate validation are unchanged.

`webrtc-sdk.json` pins the SDK source, official builder, depot_tools, patch and all
four source files before/after patching. `build_webrtc_sdk.py` rejects unexpected inputs.
The CI workflow first proves that both regression tests fail with the old getter
behavior, then runs every `VCMTimingTest` with the fix. Only after that gate can
it build a universal macOS framework and an Android AAR with the three supported
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
