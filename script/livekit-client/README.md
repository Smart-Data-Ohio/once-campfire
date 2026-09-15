# LiveKit browser SDK bundle

Campfire serves the checked-in `vendor/javascript/livekit-client.js` through its import map. Browsers do not fetch the SDK from a third-party CDN, and ordinary Rails development and container builds do not require Node.js.

The same build produces the huddle's RNNoise microphone filter, because it has the same "no CDN, no Node.js at runtime" requirement:

| File | Purpose |
| --- | --- |
| `vendor/javascript/livekit-client.js` | The LiveKit browser SDK, pinned in the import map as `livekit-client`. |
| `vendor/javascript/noise-suppressor.js` | `RnnoiseWorkletNode` and `loadRnnoise` from `@sapphi-red/web-noise-suppressor`, pinned as `noise-suppressor`. The package's Speex, GTCRN and noise-gate nodes are tree-shaken away. |
| `vendor/javascript/noise-suppressor-worklet.js` | The RNNoise AudioWorklet processor, copied verbatim. It cannot be bundled because `audioWorklet.addModule()` loads it by URL into its own global scope. |
| `vendor/javascript/rnnoise.wasm`, `vendor/javascript/rnnoise-simd.wasm` | The model. The SIMD build is chosen at runtime when the browser supports it. |

Propshaft serves the worklet and the two binaries; `app/views/layouts/_huddle.html.erb` passes their digested URLs to the huddle controller. See the [quality assessment](../../docs/huddle-quality.md) for what the filter does and how to check it.

To regenerate after changing the pinned SDK version:

```sh
cd script/livekit-client
npm ci
npm run build
```

Commit `package.json`, `package-lock.json`, the generated JavaScript, and its license/notice files together. The lockfile preserves package integrity hashes. Use a current Node.js LTS release for the build tools.
