# Audio and video quality assessment

Assessed September 14, 2026 against the checked-in LiveKit client 2.22.3 and current official documentation. The [applied settings](#applied-settings-september-15-2026) section records what Campfire now requests; the rest of this document remains the proposed order of work and does not change deploy infrastructure.

## Starting point

The huddle implements microphone audio, screen video, and — since the [Camera](#camera) slice below — camera video. Camera publishing used to be intentionally absent from both the interface and authorization grants; the grant change, controls, and authorization tests from step 5 have now landed, and only the codec comparison there remains future work.

Campfire explicitly enables adaptive streams and dynacast. The pinned SDK supplies browser echo cancellation, automatic gain control, noise suppression, supported voice isolation, audio redundant encoding (RED), and simulcast defaults. Its default audio preset caps bitrate at 48 kbps. Its default screen encoder uses the 1080p/15 fps preset, capped at 2.5 Mbps. These are requested capture/encoding settings, not measured output quality or guaranteed frame rates. Sources: the installed SDK's `src/room/defaults.ts` and `src/room/track/options.ts`, rebuilt according to the [SDK guide](../script/livekit-client/README.md).

Local tests establish actual media transport and decoded video. They do not establish microphone sound quality, internet reliability, readable small text, or multi-user capacity.

## Recommended order

1. **Establish a two-machine network pilot.** Put the authorization gateway behind trusted TLS, keep raw LiveKit signaling private, and configure reachable media ports with TURN/TLS fallback. Verify direct UDP and a forced relay connection separately. TURN covers restrictive networks; UDP remains the preferred transport. [LiveKit deployment guidance](https://docs.livekit.io/transport/self-hosting/deployment/)
2. **Measure quality before changing defaults.** Collect per-call RTT, packet loss, jitter, received bitrate, decoded resolution/frame rate, freezes, and direct-versus-relayed transport. Add a simple connection indicator and a details panel. Do not log join tokens, screen contents, or microphone recordings. Use a repeatable test call to compare changes.
3. **Make ordinary conversation reliable.** Keep echo cancellation and RED on for voice. Add microphone/output selection, a microphone meter, and a pre-call device check. Evaluate background-noise handling with headsets, laptop speakers, and representative browsers. Browser processing support varies. [Noise and echo cancellation](https://docs.livekit.io/transport/media/noise-cancellation/)
4. **Offer screen profiles for the content.** Start with a text/slides profile targeting 1080p at 15 fps and a motion profile targeting 1080p at 30 fps. Let bandwidth adaptation reduce quality. Test actual code readability at the receiving window's size; resolution alone does not prove readability. These profiles are proposals based on the pinned SDK presets. [Screen sharing](https://docs.livekit.io/transport/media/screenshare/)
5. **Evaluate camera video separately.** Begin with a proposed 720p/30 fps target and adaptive lower layers. Compare VP8/H.264 compatibility with VP9/AV1 efficiency on the team's actual devices before selecting a default. The 720p/30 target, the explicit grant change, the controls, and the authorization tests have landed (see [Camera](#camera)); the codec comparison is still open. [Codecs and quality controls](https://docs.livekit.io/transport/media/advanced/)

High-fidelity stereo should be an optional music/media mode. Its higher bitrate and reduced speech processing can help that use case, but it should not replace the conversation preset without listening tests. LiveKit documents separate hi-fi settings and recommends testing them under real conditions. [Hi-fi audio and RED](https://docs.livekit.io/transport/media/advanced/#hi-fi-audio)

## Applied settings, September 15, 2026

Two pieces of employee feedback moved ahead of the measurement work above: a shared screen could only be seen in the small floating panel, and the microphone carried too much background noise. The settings below are now requested by `app/javascript/controllers/huddle_controller.js`. They are requested capture and encoding settings, not measured output.

**Most of what is listed here equals the pinned SDK's own defaults.** `AudioPresets.music`, `dtx: true`, `red: true`, `degradationPreference: "maintain-resolution"` for a screen share, `ScreenSharePresets.h1080fps15.encoding`, and all four microphone constraints including `voiceIsolation` are what livekit-client 2.22.3 would have used anyway (`publishDefaults` and `audioDefaults` in its `src/room/defaults.ts`). Campfire spells them out so an SDK upgrade cannot change them silently, but writing them down changed no behavior. The genuinely new behavior is the RNNoise processor, `contentHint: "detail"`, the screen-share audio settings, and the viewing controls.

### Microphone

The SDK's `audioCaptureDefaults` already asked for echo cancellation, automatic gain control, noise suppression and voice isolation. Campfire now spells all four out in its own `Room` options so an SDK upgrade cannot change them silently; the requested values are unchanged. `voiceIsolation` is an "ideal" constraint, so browsers without it simply ignore it; Chrome on macOS and Windows is where it currently applies. Publishing keeps the SDK defaults of `AudioPresets.music` (48 kbps), `dtx: true` and `red: true`.

On top of that, Campfire runs **RNNoise** on the microphone as a LiveKit audio `TrackProcessor`. LiveKit Cloud's Krisp filter is not licensed for a self-hosted deployment, so the model runs in the browser instead:

- **Package:** [`@sapphi-red/web-noise-suppressor`](https://github.com/sapphi-red/web-noise-suppressor) 0.4.0, MIT. It was chosen over `@shiguredo/noise-suppression` (which needs Chrome-only Insertable Streams) and over raw `rnnoise-wasm` bindings (which would mean writing and maintaining the AudioWorklet here). Only its RNNoise entry points are bundled; the Speex, GTCRN and noise-gate nodes are dropped by the build.
- **Licenses:** the wrapper is MIT. The WebAssembly it embeds is `@shiguredo/rnnoise-wasm` 2022.2.0 (Apache 2.0), which is a build of Xiph's RNNoise (BSD 3-Clause). All three are recorded in `vendor/javascript/livekit-client.NOTICES.txt`.
- **Size:** 1.4 KB of module JavaScript, a 64 KB worklet, and one WebAssembly binary of 153 KB (or 154 KB for the SIMD build, chosen at runtime). All are served from this origin through Propshaft; nothing is fetched from a CDN. They load only when somebody joins a huddle.
- **Cost:** RNNoise is a small recurrent network working on 10 ms frames. It costs roughly one percent of one core on a modern laptop and runs on the AudioWorklet thread, so it does not compete with rendering. It is far cheaper than a spectral deep-learning denoiser.
- **Sample rate:** RNNoise is trained for 48 kHz. Campfire reuses LiveKit's `AudioContext` when it already runs at 48 kHz and otherwise opens a dedicated 48 kHz context for the processor.
- **Fallback:** the microphone always keeps publishing, and joining a huddle never waits on the processor. A browser that genuinely cannot run the filter — no `AudioWorkletNode` or WebAssembly, a `NotSupportedError` — latches the control off for the rest of the page and it reads "Noise suppression unavailable". A transient failure instead, such as a worklet or model that did not download, leaves the control enabled, says "Noise suppression couldn't start… try again", and is not written to storage, so leaving and rejoining tries again. Every request goes through one queue so a double-click cannot leave the processor and the button disagreeing.
- **Double suppression:** the browser's own `noiseSuppression`, Chrome's `voiceIsolation` and RNNoise all run on the same signal. Stacking them is not obviously better than one good stage and can thin out quiet speech. Deciding that needs an A/B listening test and belongs in the measurement work above; nothing here establishes which combination sounds best.
- **Content Security Policy:** Campfire does not send a CSP today. If one is introduced, `script-src` needs `'wasm-unsafe-eval'` because the worklet instantiates the model from an `ArrayBuffer`. No `worker-src` entry is needed: an AudioWorklet module is fetched under `script-src`, and both the worklet and the binary are same-origin.

The huddle controls carry a "Noise suppression on/off" toggle. It defaults to on and is remembered per browser in `localStorage` under `campfire.huddle.noiseSuppression`. Browser-level suppression stays on either way. The Mute button sits first in the controls and turns red while the microphone is off.

### Screen sharing

`setScreenShareEnabled` now requests `contentHint: "detail"`, `surfaceSwitching: "include"`, and tab audio (`audio: true`, `systemAudio: "exclude"`). Screen-share audio was already inside the token's publish grant.

**Capture and encoding are separate ceilings.** No `resolution` is passed, so the SDK applies its own 1080p/30 capture constraint — and keeps its exemption for Safari 17, which cannot be constrained. Naming a preset's `resolution` here would have been a trap: a preset's resolution carries its frame rate, so asking for `h1080fps15.resolution` would have capped *capture* at 15 fps as well. Capture stays at 30 fps; the encoder is what limits the stream.

`systemAudio: "exclude"` is a deliberate trade-off. Including system audio is the only way to carry sound from a native application being demonstrated, but on Windows an "Entire screen" capture with system audio also captures the huddle's own output from the speakers and feeds it back in. Browser echo cancellation does not run on a display-capture track, so that loop is not cancelled. Tab audio still covers the common case of sharing a browser tab playing a video. Somebody who needs native application audio has to route it separately today.

The shared audio track publishes with `dtx: false`. Discontinuous transmission is tuned for speech and cuts the stream during perceived silence, which chops music and quiet passages in a demonstration. The microphone keeps `dtx: true`.

Publishing uses `ScreenSharePresets.h1080fps15.encoding` (1920×1080, up to 2.5 Mbps, 15 fps) with `degradationPreference: "maintain-resolution"` — both the SDK's defaults, written out rather than inherited. Capturing at 30 and encoding at 15 is the SDK's own arrangement; the encoder drops every other frame rather than the capture missing them. Small code text stays readable under congestion because frames are dropped before resolution is. With simulcast on (also the SDK default) the publisher also sends a 960×540/15 layer at 625 kbps, so the uplink ceiling is about **3.1 Mbps**.

**1080p/30 is the candidate to test, not the current setting.** `ScreenSharePresets.h1080fps30` would raise the top layer to 5 Mbps and the simulcast layer to 960×540/30 at 1.25 Mbps, about **6.25 Mbps** of publisher uplink — roughly double. That is a real network decision for an office link shared by several people, so it waits for the measurement work above rather than shipping on the strength of "sharper is better".

### Camera

Joining stays audio-only. The camera is off on every join, is turned on explicitly with the **Camera** toggle after Share screen, and the choice is deliberately not remembered in `localStorage`. The button reads "Camera off"/"Camera on" with `aria-pressed`, matching the Mute and Share screen styling. One captioned tile appears per published camera track — the local preview (muted, mirrored with CSS) plus each remote camera — and tiles disappear on unpublish or leave. Turning the camera off unpublishes the track rather than calling `setCameraEnabled(false)`, which would only mute it and keep the device claimed; unpublishing releases the camera and removes the tile on both sides. Camera and screen share may be on at the same time; mute never touches the camera; leaving stops the camera track with the rest of local media. A denied or failed camera shows "Camera wasn’t started. Allow camera access to try again." in the status line, leaves the microphone and the huddle connected, and leaves the button retryable.

**Requested.** `app/javascript/controllers/huddle_controller.js` `#roomOptions` now spells out the step 5 proposal:

- Capture: `videoCaptureDefaults` with `deviceId: { ideal: "default" }` and `resolution: VideoPresets.h720.resolution` (1280×720 at 30 fps). This is the pinned SDK's own `videoDefaults` written out (`src/room/defaults.ts`), so it pins behavior against upgrades rather than changing it.
- Encoding: `publishDefaults.videoEncoding` is `VideoPresets.h720.encoding` — a top layer of up to 1.7 Mbps at 30 fps. With capture already constrained to 720p this matches what the SDK would derive from the captured dimensions on its own.
- Layers: `simulcast: true`, the SDK default. With no explicit `videoSimulcastLayers`, the publisher adds the default 640×360 (450 kbps, 20 fps) and 320×180 (160 kbps, 20 fps) layers, so `adaptiveStream` can size each subscription from its rendered element.
- Codec: unchanged. Campfire sets no `videoCodec`, so the SDK default VP8 (with backup-codec negotiation) applies. Codec comparison remains future measurement work.
- Degradation: the camera currently inherits the shared `degradationPreference: "maintain-resolution"` from the room's `publishDefaults` rather than the SDK's camera-specific `"maintain-framerate"` default. Whether a talking-head tile should instead trade resolution for smoothness is an open measurement question, not a settled choice.

Camera tiles have no expand or full-screen control in this slice. When a shared screen is expanded into theater mode the tiles shrink to a small thumbnail strip so they never cover the screen; the [overlap check](#how-to-verify) pins that down.

**Measured.** `test/system/huddles_test.rb` runs two headless browsers with a synthetic camera: each side turns its camera on and the other side asserts received video bytes plus a decoded remote frame (`videoWidth > 0`, `readyState >= 2`), turning a camera off removes the tile on both sides, leaving ends every local track including the camera, a camera that fails to start keeps the huddle connected with the button retryable, a rejoin comes back audio-only, mute leaves the camera decoding, and a camera tile survives channel navigation on the same peer connection. Theater mode with cameras on asserts the tiles stay visible without overlapping the expanded screen.

**Not measured.** No codec comparison (VP8 vs H.264/VP9/AV1 on the team's devices), no degradation-preference comparison, no multi-user capacity numbers, no per-call statistics panel — those belong to the measurement work in steps 1–2. The synthetic headless camera proves transport and decode, not real-device capture quality, and `chrome://webrtc-internals` remains the hand-check tool for which simulcast layer is actually being received.

### Viewing a shared screen

Every shared screen now carries an always-visible **Expand** and **Full screen** control, and the video itself responds to a click (expand) and a double-click (full screen).

- **Theater mode** keeps everything inside the page: the huddle panel grows to fill the viewport, the chosen screen fills the panel, and the caption, people list and controls stay visible. Escape and the Collapse button both leave it, and focus returns to the control that opened it. When two people share at once the other screens stay on as small thumbnails with their own Expand buttons, and the banner button turns into "Next screen" so it cycles rather than going dead.
- **Full screen** uses the Fullscreen API on the `<figure>`, which keeps the caption and the controls with the picture. If that is refused it falls back to `video.requestFullscreen()`, then to `video.webkitEnterFullscreen()` for iPhone Safari, which can only do full screen on a video element and shows its own player without the caption. If nothing works the share is expanded into theater mode instead and the panel says so. `fullscreenchange` and `webkitendfullscreen` both restore the button state and the focus.
- **Quality follows size.** The room runs with `adaptiveStream`, so LiveKit sizes each subscription from the rendered element: enlarging the element is what actually asks the server for a sharper layer. `emitTrackUpdate` takes the *smaller* of the adaptive size and any manual request, so the explicit `setVideoQuality(VideoQuality.HIGH)` and `setVideoDimensions` calls cannot out-argue the observer while the element is still small — they help only once the element has been resized, where they ask for the full layer straight away instead of waiting for the next observer callback. Collapsing calls `setVideoQuality(VideoQuality.HIGH)` again, which clears the requested dimensions and hands control back to adaptive streaming.
- **Noticing a share.** The panel shows "<name> is sharing a screen" with a View button, and the room header grows a green button next to Join huddle for anybody who has scrolled away or has the panel behind a mobile drawer.
- **Not covered by tests.** Headless Chrome refuses real full screen, so the `fullscreenchange` and `webkitendfullscreen` paths — restoring the button state and the focus after leaving full screen — are exercised only by hand. The tests cover the request chain and the refusal fallback, not a successful entry and exit.

### How to verify

1. Join a huddle in two browsers with `bin/livekit-local serve` as described in [local operation](huddles.md).
2. Share a screen showing small code text. Click Expand in the other browser and confirm the text becomes readable rather than an upscaled thumbnail. In Chrome, `chrome://webrtc-internals` should show the inbound frame width rising after expanding.
3. Press Escape, then use Full screen and Escape again. Focus should land back on the control you used.
4. With the huddle connected, run this in the console to confirm the processor is on the published track:

   ```js
   Stimulus.getControllerForElementAndIdentifier(document.getElementById("channel-huddle"), "huddle")
     .room.localParticipant.getTrackPublication("microphone").audioTrack.getProcessor()?.name
   // "campfire-rnnoise"
   ```

5. Toggle "Noise suppression" off and confirm the same expression returns `undefined`, that `localStorage.getItem("campfire.huddle.noiseSuppression")` is `"off"`, and that the preference survives rejoining.
6. Toggle it back on mid-call and confirm the processor reattaches, then mute and unmute and confirm it is still attached afterwards.
7. Listen with a noise source running — a fan, typing, a nearby conversation — and compare the toggle on and off. RNNoise removes steady broadband noise well and keyboard clicks partially; it is not a replacement for a headset in a loud room.
8. Share an "Entire screen" on Windows with the huddle audio playing through speakers and confirm there is no feedback loop. Then share a browser tab playing a video and confirm its audio reaches the other participant.
9. Join audio-only in two browsers and confirm no camera tiles render. Turn both cameras on and confirm each side sees its own mirrored preview plus the other side's captioned tile. In `chrome://webrtc-internals` the publishers should show three outbound camera layers (720p plus the 360p/180p simulcast layers) and each subscriber should receive the layer matching its rendered tile size.
10. With both cameras on, share a screen and expand it on the other side: the camera tiles should shrink to a thumbnail strip without covering the screen. Deny camera access in a third browser (or revoke it mid-call), confirm the huddle stays connected with "Camera wasn’t started…", allow it again, and confirm the toggle retries cleanly.

`test/system/huddles_test.rb` covers expand and collapse, the full-screen request chain and its fallback, the header indicator, two simultaneous shares each staying reachable from theater mode, the toggle switching off, back on, and surviving a rejoin, the processor surviving mute and unmute, a processor that fails to start, and the camera exchange above: two-way decoded video, toggle-off removal on both sides, leave cleanup, failure retry, audio-only rejoin, mute independence, navigation survival, and the theater-mode overlap check. Real full screen and the Windows audio behavior are hand checks; headless Chrome cannot produce them.

## Acceptance exercise

Use two people first, then proposed test points of six and twelve participants; these are test sizes, not a capacity claim. Exercise office Wi-Fi, a home network, a restrictive network through TURN, and controlled loss/limited-bandwidth conditions. Include simultaneous speech, a screen of small code text, scrolling, motion, mute/unmute, and reconnects. Check both subjective listening/readability and the measured transport statistics. Repeat revocation tests while media is flowing so quality work preserves enforcement.

Choose a server size and region from measured CPU, bandwidth, and participant experience. An existing application VM should not be assumed to have spare media capacity. LiveKit identifies CPU and bandwidth as its principal scaling constraints. [Hosting resources](https://docs.livekit.io/transport/self-hosting/deployment/#resources)

The Discord-inspired layout and Markdown work remain the following product phase. Device controls, connection status, and an expandable screen view should fit into that design rather than become a second competing interface.
