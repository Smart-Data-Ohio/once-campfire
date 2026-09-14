# LiveKit browser SDK bundle

Campfire serves the checked-in `vendor/javascript/livekit-client.js` through its import map. Browsers do not fetch the SDK from a third-party CDN, and ordinary Rails development and container builds do not require Node.js.

To regenerate after changing the pinned SDK version:

```sh
cd script/livekit-client
npm ci
npm run build
```

Commit `package.json`, `package-lock.json`, the generated JavaScript, and its license/notice files together. The lockfile preserves package integrity hashes. Use a current Node.js LTS release for the build tools.
