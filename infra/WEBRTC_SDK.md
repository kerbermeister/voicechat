# Native call synchronization SDK

SDK36 Android texture candidate (not media-qualified) is based on the exact
SDK35 source. Android's SurfaceTextureHelper permits only one texture in flight;
keeping that texture in a delayed render queue can block the next decoded frame.
For a bounded render wait over20ms the Android smoother now detaches a pixel-exact
I420 copy before queuing it, preserving frame metadata and the original deadline.
Immediate/CPU frames, failed mappings and the existing far-future guard retain
their previous policy. The copy is invoked only on Android; Mac native buffer
behavior, PCM, audio buffers, NetEq, codecs and E2EE are unchanged.

Expected evidence is117 timing/crypto/NetEq +56 recovery native cases. Three new
cases cover decoder-texture release with exact strided Y/U/V samples and frame
metadata, unchanged fast/far-future/CPU paths and unavailable conversion. The
old ownership policy must fail the compiled copy regression before a platform
artifact can qualify. Source/patch receipts and actual-call speech/output/crypto
checks remain required. The user-accepted Android LiveKit34 result is retained.

SDK35 compiler candidate (`d5c8be1`, 2026-11-08) is now integrated without
changing application artifact pins. Its exact CI42465826333 passed117
timing/crypto/NetEq +53 recovery C++ cases, old-policy negative controls,
Mac compiled policy/crypto-worker checks and Android16 audio-clock/2 decoder
API cases. Both exact platform artifacts were independently verified.
Two consecutive full Mac LiveKit calls passed original raw/corrected80ms,
speech, added-voice, required E2EE and output-continuity gates. Android35
media qualification and exact signed application release checks remain open.

The candidate gives each crypto worker native media scheduling priority;
Android never lowers an already stronger priority. Android AudioTimestamp
provides the measured device queue instead of a fixed estimate. The measured
local audio delay also accompanies the video sync target, so a legitimate
402ms wait for397ms audio is not rejected by the former fixed250ms final
render guard. The separate250ms RTP-clock guards, stale-state cleanup and
rejection of unrelated multi-second targets remain. PCM, NetEq, codecs,
audio-buffer policy and E2EE algorithms are unchanged from SDK34.
The accepted Android LiveKit34 measurement is a documented exception only
for that emulator run, not P2P, physical hardware or a signed APK.

The macOS client pins SDK26 (WebRTC 150.7871.04, source `7227897`).
Android still uses its existing dependency. Exact SDK26 source, compiler
receipts and platform evidence are recorded in the
[technical journal](../docs/iterations/native-av-sync-after62.md).

The fork pins WebRTC, the official builder, depot_tools and source inputs in
`webrtc-sdk.json`. It synchronizes video to natural audio presentation delay.
The video target uses signed packet arrival versus fitted RTP-clock offset
and relative RTCP network delay. Effective render delay respects explicit
minimum, maximum and low-latency bounds. Missing or stopped streams clear the
custom target after two sync intervals. Detach, reassignment and timing reset
also clear it. The timestamp extrapolator resets slope and offset covariance
on alarms while preserving its opt-out.

The SDK sets `WebRTC-ForcePlayoutDelay/min_ms:0,max_ms:10000/` when the caller
has not supplied the field-trial key. Explicit settings retain precedence.
This receiver policy sends no outgoing playout hint. macOS schedules the audio
encoder on the upstream audio-priority task queue.

macOS LiveKit calls associate subscriber audio/video by participant using a
local SDP transform. Publisher SDP, codecs, track IDs and transport bytes
remain unchanged. Unknown and conflicting formats keep their original
associations. The native synchronizer handles one pair per group, so multiple
audio/video sources retain their associations. For subscribed camera tracks the
Mac client sets a 70 ms minimum. It sets a 40 ms NetEq minimum on subscribed
microphones only in calls started as video. Direct video calls set an 80 ms
minimum on the remote user's microphone receiver. Ordinary audio calls keep
their existing buffer policy. The production SFU sends its existing
130 ms video playout hint. Opus DTX keeps its standard setting.

Strict crypto readiness now also applies to already whitelisted server-injected
blank frames: absent participant/shared current key, these frames stop before
the decoder. Once that key exists, blank-frame behavior is retained. The SDK's
manual KeyProviderOptions copy constructor omitted the strict-ready flag;
standard memberwise copying now preserves it. AES-GCM, KDF, key format, payload
whitelist, legacy false-mode and certificate validation remain. Component tests
cover direct/provider option copies and shared/participant nonzero key indices.
Real missing-key and positive decrypted-content controls are still required.

Use an isolated runner with at least18GB free, Python3.11+ and official tools:

```sh
git clone https://github.com/webrtc-sdk/webrtc-build.git sdk-builder
git -C sdk-builder checkout 717ec1dc5a94389d691e09cccaf3d7b3364fb4b7
python3 infra/build_webrtc_sdk.py test --builder sdk-builder/build --work /tmp/vc-sdk-test --output /tmp/vc-sdk-tests
```

Use fresh work/output paths. Substitute `macos` or `android` for `test` on the
appropriate runner. The workflow builds Mac arm64 with Xcode 26.0 and can build Android for three
ABIs. Each source/toolchain receipt must match exactly. Platform checks exercise
actual Objective-C and Android factory initialization. The macOS check also
verifies the typed audio/video receiver floor setters. The Android verifier uses the producer
JDK when present. These checks do not exercise devices or media. Packaging
includes generated third-party notices in framework resources and Android
assets. The workflow has read-only permissions and no release secrets.

Binary pins belong in `webrtc-sdk-artifacts.json`. CocoaPods overrides only
WebRTC-SDK through its checksum-pinned archive. Android does not consume this
archive or manifest. A changed same-version external podspec requires
`pod update WebRTC-SDK --no-repo-update`: verify the generated lock and actual
embedded framework UUID; an edited lock is not proof of installation. Keep SPM
disabled. Dependency prereleases are distinct from application updates.

Native P2P/SFU calls, actual encrypted-content controls, ordinary-voice latency
and matched speech must pass before app publication. Raw/source-corrected A/V and
added voice delay stay within80ms; STOI margin0.005, level tolerance0.15dB and at
least4 matched speech clips per phase remain unchanged. Missing or failed
measurements do not qualify. Physical acoustic/display latency and Xiaomi/iPhone
acceptance remain separate evidence. The sole user acceptance entry is
[UA-08.C06](../docs/user-acceptance.md).
