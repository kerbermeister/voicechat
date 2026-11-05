# Native call synchronization SDK

**SDK7 candidate, not release-qualified (2026-11-05).** Installed application
channels remain1.19.14(62). Exact sourceb29604e passes86/86 C++ tests, zero skips
and15 original-behavior negative regressions in run41983111458. Both platform
libraries are building in run42006621067. Application binary pins still refer
to earlier internal SDKs until the complete SDK7 pair is verified; they must
not be released. Earlier failed media attempts remain in the
[technical journal](../docs/iterations/native-av-sync-after62.md).

The fork pins WebRTC150.7871.04, the official builder/depot_tools and19 source
inputs in `webrtc-sdk.json`. SDK7 synchronizes video to natural audio delay
without adding an audio synchronization buffer. Its video target combines
audio delay, signed packet-arrival versus fitted RTP-clock offset and relative
RTCP network delay. Effective render delay respects explicit minimum/maximum
and low-latency bounds; the ordinary jitter target remains available for stats
and reset logic. An unavailable RTP fit produces no custom target. Missing or
stopped streams clear the target after two sync intervals; detach/reassignment
and timing reset also clear it. The timestamp extrapolator resets full slope/
offset covariance on alarms, preserving its existing explicit opt-out.

Initialization defaults to
`WebRTC-ForcePlayoutDelay/min_ms:90,max_ms:10000/` only when the caller has not
provided this field-trial key. Explicit options and invalid-input validation
remain. The default is a receiver policy; no outgoing hint is forced.

LiveKit assigns distinct MediaStreams to tracks. Opted-in macOS/Android call
rooms associate subscriber audio/video by participant using a local SDP
transform, preserving actual track IDs and transport/codec bytes. Publisher
SDP, browser/iOS/Linux/Windows paths and other room types do not opt in. Unknown
or conflicting stream formats remain unchanged. No global SFU grouping policy
is required. Test fixtures use the same subscriber transform.

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
appropriate runner. The workflow selects Xcode26.0 and builds Mac arm64 and
Android3ABIs. Each source/toolchain receipt must match exactly. Nine configuration
cases per platform check the actual Objective-C initialization implementation
and Android AAR initialization builder. The Android verifier uses the producer
JDK when present. These checks do not exercise devices or media. Packaging
includes generated third-party notices in framework resources and Android
assets. The workflow has read-only permissions and no release secrets.

Binary pins belong in `webrtc-sdk-artifacts.json`. The Android helper checks AAR
hash/size and Maven metadata on download/reuse. Gradle must force both consumers
to that same immutable module. CocoaPods overrides only WebRTC-SDK through its
checksum-pinned archive. A changed same-version external podspec requires
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
