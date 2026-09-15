# Audio and video quality assessment

Assessed September 14, 2026 against the checked-in LiveKit client 2.22.3 and current official documentation. These are proposed next steps; this assessment does not change media settings or deploy infrastructure.

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

## Acceptance exercise

Use two people first, then proposed test points of six and twelve participants; these are test sizes, not a capacity claim. Exercise office Wi-Fi, a home network, a restrictive network through TURN, and controlled loss/limited-bandwidth conditions. Include simultaneous speech, a screen of small code text, scrolling, motion, mute/unmute, and reconnects. Check both subjective listening/readability and the measured transport statistics. Repeat revocation tests while media is flowing so quality work preserves enforcement.

Choose a server size and region from measured CPU, bandwidth, and participant experience. An existing application VM should not be assumed to have spare media capacity. LiveKit identifies CPU and bandwidth as its principal scaling constraints. [Hosting resources](https://docs.livekit.io/transport/self-hosting/deployment/#resources)

The Discord-inspired layout and Markdown work remain the following product phase. Device controls, connection status, and an expandable screen view should fit into that design rather than become a second competing interface.
