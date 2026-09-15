# Audio and video quality assessment

Assessed September 14, 2026 against the checked-in LiveKit client 2.22.3 and current official documentation. The [applied settings](#applied-settings-september-15-2026) section records what Campfire now requests; the rest of this document remains the proposed order of work and does not change deploy infrastructure.

## Starting point

The current huddle implements microphone audio and screen video. Camera publishing is intentionally absent from both the interface and authorization grants.

Campfire explicitly enables adaptive streams and dynacast. The pinned SDK supplies browser echo cancellation, automatic gain control, noise suppression, supported voice isolation, audio redundant encoding (RED), and simulcast defaults. Its default audio preset caps bitrate at 48 kbps. Its default screen encoder uses the 1080p/15 fps preset, capped at 2.5 Mbps. These are requested capture/encoding settings, not measured output quality or guaranteed frame rates. Sources: the installed SDK's `src/room/defaults.ts` and `src/room/track/options.ts`, rebuilt according to the [SDK guide](../script/livekit-client/README.md).

Local tests establish actual media transport and decoded video. They do not establish microphone sound quality, internet reliability, readable small text, or multi-user capacity.

## Recommended order

1. **Establish a two-machine network pilot.** Put the authorization gateway behind trusted TLS, keep raw LiveKit signaling private, and configure reachable media ports with TURN/TLS fallback. Verify direct UDP and a forced relay connection separately. TURN covers restrictive networks; UDP remains the preferred transport. [LiveKit deployment guidance](https://docs.livekit.io/transport/self-hosting/deployment/)
2. **Measure quality before changing defaults.** Collect per-call RTT, packet loss, jitter, received bitrate, decoded resolution/frame rate, freezes, and direct-versus-relayed transport. Add a simple connection indicator and a details panel. Do not log join tokens, screen contents, or microphone recordings. Use a repeatable test call to compare changes.
3. **Make ordinary conversation reliable.** Keep echo cancellation and RED on for voice. Add microphone/output selection, a microphone meter, and a pre-call device check. Evaluate background-noise handling with headsets, laptop speakers, and representative browsers. Browser processing support varies. [Noise and echo cancellation](https://docs.livekit.io/transport/media/noise-cancellation/)
4. **Offer screen profiles for the content.** Start with a text/slides profile targeting 1080p at 15 fps and a motion profile targeting 1080p at 30 fps. Let bandwidth adaptation reduce quality. Test actual code readability at the receiving window's size; resolution alone does not prove readability. These profiles are proposals based on the pinned SDK presets. [Screen sharing](https://docs.livekit.io/transport/media/screenshare/)
5. **Evaluate camera video separately.** Begin with a proposed 720p/30 fps target and adaptive lower layers. Compare VP8/H.264 compatibility with VP9/AV1 efficiency on the team's actual devices before selecting a default. Camera support also needs an explicit grant change, controls, and authorization tests. [Codecs and quality controls](https://docs.livekit.io/transport/media/advanced/)

High-fidelity stereo should be an optional music/media mode. Its higher bitrate and reduced speech processing can help that use case, but it should not replace the conversation preset without listening tests. LiveKit documents separate hi-fi settings and recommends testing them under real conditions. [Hi-fi audio and RED](https://docs.livekit.io/transport/media/advanced/#hi-fi-audio)

## Applied settings, September 15, 2026

Two pieces of employee feedback moved ahead of the measurement work above: a shared screen could only be seen in the small floating panel, and the microphone carried too much background noise. The settings below are now requested by `app/javascript/controllers/huddle_controller.js`. They are requested capture and encoding settings, not measured output.

### Microphone

The SDK's `audioCaptureDefaults` already asked for echo cancellation, automatic gain control, noise suppression and voice isolation. Campfire now spells all four out in its own `Room` options so an SDK upgrade cannot change them silently. `voiceIsolation` is an "ideal" constraint, so browsers without it simply ignore it; Chrome on macOS and Windows is where it currently applies. Publishing keeps the SDK defaults of `AudioPresets.music` (48 kbps), `dtx: true` and `red: true`.

On top of that, Campfire runs **RNNoise** on the microphone as a LiveKit audio `TrackProcessor`. LiveKit Cloud's Krisp filter is not licensed for a self-hosted deployment, so the model runs in the browser instead:

- **Package:** [`@sapphi-red/web-noise-suppressor`](https://github.com/sapphi-red/web-noise-suppressor) 0.4.0, MIT. It was chosen over `@shiguredo/noise-suppression` (which needs Chrome-only Insertable Streams) and over raw `rnnoise-wasm` bindings (which would mean writing and maintaining the AudioWorklet here). Only its RNNoise entry points are bundled; the Speex, GTCRN and noise-gate nodes are dropped by the build.
- **Licenses:** the wrapper is MIT. The WebAssembly it embeds is `@shiguredo/rnnoise-wasm` 2022.2.0 (Apache 2.0), which is a build of Xiph's RNNoise (BSD 3-Clause). All three are recorded in `vendor/javascript/livekit-client.NOTICES.txt`.
- **Size:** 1.4 KB of module JavaScript, a 64 KB worklet, and one WebAssembly binary of 153 KB (or 154 KB for the SIMD build, chosen at runtime). All are served from this origin through Propshaft; nothing is fetched from a CDN. They load only when somebody joins a huddle.
- **Cost:** RNNoise is a small recurrent network working on 10 ms frames. It costs roughly one percent of one core on a modern laptop and runs on the AudioWorklet thread, so it does not compete with rendering. It is far cheaper than a spectral deep-learning denoiser.
- **Sample rate:** RNNoise is trained for 48 kHz. Campfire reuses LiveKit's `AudioContext` when it already runs at 48 kHz and otherwise opens a dedicated 48 kHz context for the processor.
- **Fallback:** a browser without `AudioWorkletNode` or WebAssembly, a worklet that fails to load, and a processor that fails to start all end the same way — the microphone publishes unprocessed, the browser's own suppression stays on, and the control reads "Noise suppression unavailable". Joining a huddle never waits on the processor.
- **Content Security Policy:** Campfire does not send a CSP today. If one is introduced, `script-src` needs `'wasm-unsafe-eval'` because the worklet instantiates the model from an `ArrayBuffer`. No `worker-src` entry is needed: an AudioWorklet module is fetched under `script-src`, and both the worklet and the binary are same-origin.

The huddle controls carry a "Noise suppression on/off" toggle. It defaults to on and is remembered per browser in `localStorage` under `campfire.huddle.noiseSuppression`. Browser-level suppression stays on either way. The Mute button sits first in the controls and turns red while the microphone is off.

### Screen sharing

`setScreenShareEnabled` now requests `contentHint: "detail"`, the 1080p resolution of `ScreenSharePresets.h1080fps30`, `surfaceSwitching: "include"`, and tab or system audio (`audio: true`, `systemAudio: "include"`). Screen-share audio was already inside the token's publish grant. A browser that refuses the whole request because it cannot capture that audio is retried once without it, so the picture is never lost to an audio capability.

Publishing uses `ScreenSharePresets.h1080fps30.encoding` (1920×1080, up to 5 Mbps, 30 fps) with `degradationPreference: "maintain-resolution"`, replacing the SDK default of 1080p/15 at 2.5 Mbps. Small code text stays readable under congestion because frames are dropped before resolution is. The higher ceiling is the main bandwidth change here and belongs in the measurement work above.

### Viewing a shared screen

Every shared screen now carries an always-visible **Expand** and **Full screen** control, and the video itself responds to a click (expand) and a double-click (full screen).

- **Theater mode** keeps everything inside the page: the huddle panel grows to fill the viewport, the chosen screen fills the panel, and the caption, people list and controls stay visible. Escape and the Collapse button both leave it, and focus returns to the control that opened it.
- **Full screen** uses the Fullscreen API on the `<figure>`, which keeps the caption and the controls with the picture. If that is refused it falls back to `video.requestFullscreen()`, then to `video.webkitEnterFullscreen()` for iPhone Safari, which can only do full screen on a video element and shows its own player without the caption. If nothing works the share is expanded into theater mode instead and the panel says so. `fullscreenchange` and `webkitendfullscreen` both restore the button state and the focus.
- **Quality follows size.** The room runs with `adaptiveStream`, so LiveKit sizes each subscription from the rendered element and an enlarged element asks the server for a sharper layer on its own; `emitTrackUpdate` takes the smaller of the adaptive size and any manual request. Expanding also calls `setVideoQuality(VideoQuality.HIGH)` and then `setVideoDimensions` with the element's real pixel size to cover the moment before the resize observer reports it. Collapsing calls `setVideoQuality(VideoQuality.HIGH)` again, which clears the requested dimensions and hands control back to adaptive streaming.
- **Noticing a share.** The panel shows "<name> is sharing a screen" with a View button, and the room header grows a green button next to Join huddle for anybody who has scrolled away or has the panel behind a mobile drawer.

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
6. Listen with a noise source running — a fan, typing, a nearby conversation — and compare the toggle on and off. RNNoise removes steady broadband noise well and keyboard clicks partially; it is not a replacement for a headset in a loud room.

`test/system/huddles_test.rb` covers expand and collapse, the full-screen request chain and its fallback, the header indicator, the remembered toggle, and a processor that fails to start.

## Acceptance exercise

Use two people first, then proposed test points of six and twelve participants; these are test sizes, not a capacity claim. Exercise office Wi-Fi, a home network, a restrictive network through TURN, and controlled loss/limited-bandwidth conditions. Include simultaneous speech, a screen of small code text, scrolling, motion, mute/unmute, and reconnects. Check both subjective listening/readability and the measured transport statistics. Repeat revocation tests while media is flowing so quality work preserves enforcement.

Choose a server size and region from measured CPU, bandwidth, and participant experience. An existing application VM should not be assumed to have spare media capacity. LiveKit identifies CPU and bandwidth as its principal scaling constraints. [Hosting resources](https://docs.livekit.io/transport/self-hosting/deployment/#resources)

The Discord-inspired layout and Markdown work remain the following product phase. Device controls, connection status, and an expandable screen view should fit into that design rather than become a second competing interface.
