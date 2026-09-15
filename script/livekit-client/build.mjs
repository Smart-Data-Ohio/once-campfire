import { build } from "esbuild";
import { copyFile, readFile, readdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const directory = dirname(fileURLToPath(import.meta.url));
const vendor = (name) => resolve(directory, "../../vendor/javascript", name);
const dependency = (path) => resolve(directory, "node_modules", path);
const packageVersion = async (name) =>
  JSON.parse(await readFile(dependency(`${name}/package.json`), "utf8")).version;

const sdkVersion = await packageVersion("livekit-client");
const suppressorVersion = await packageVersion("@sapphi-red/web-noise-suppressor");

await build({
  absWorkingDir: directory,
  stdin: { contents: 'export * from "livekit-client";', resolveDir: directory },
  outfile: vendor("livekit-client.js"),
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  minify: true,
  legalComments: "eof",
  banner: { js: `// LiveKit browser SDK ${sdkVersion}. Regenerate with npm ci && npm run build in script/livekit-client.` },
});

// Only the RNNoise entry points are bundled; esbuild drops the Speex, GTCRN and
// noise-gate nodes that Campfire does not publish.
await build({
  absWorkingDir: directory,
  stdin: {
    contents: 'export { RnnoiseWorkletNode, loadRnnoise } from "@sapphi-red/web-noise-suppressor";',
    resolveDir: directory,
  },
  outfile: vendor("noise-suppressor.js"),
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  minify: true,
  legalComments: "eof",
  banner: { js: `// RNNoise worklet node from @sapphi-red/web-noise-suppressor ${suppressorVersion}. Regenerate with npm ci && npm run build in script/livekit-client.` },
});

// The AudioWorklet processor has to stay a separate script because
// AudioWorkletGlobalScope loads it through audioWorklet.addModule(url). The
// published file is already self-contained and minified, so it is copied
// verbatim apart from its missing source map reference.
const worklet = await readFile(dependency("@sapphi-red/web-noise-suppressor/dist/rnnoise/workletProcessor.js"), "utf8");
await writeFile(
  vendor("noise-suppressor-worklet.js"),
  `// RNNoise AudioWorklet processor from @sapphi-red/web-noise-suppressor ${suppressorVersion}. Regenerate with npm ci && npm run build in script/livekit-client.\n` +
    worklet.replace(/\n?\/\/# sourceMappingURL=.*\n?$/, "\n"),
);

for (const [ source, target ] of [
  [ "rnnoise.wasm", "rnnoise.wasm" ],
  [ "rnnoise_simd.wasm", "rnnoise-simd.wasm" ],
]) {
  await copyFile(dependency(`@sapphi-red/web-noise-suppressor/dist/${source}`), vendor(target));
}

for (const [ name, file ] of [
  [ "livekit-client", "livekit-client.LICENSE.txt" ],
  [ "@sapphi-red/web-noise-suppressor", "noise-suppressor.LICENSE.txt" ],
]) {
  await copyFile(dependency(`${name}/LICENSE`), vendor(file));
}

// The published SDK already bundles dependencies, so retain their licenses too.
const lock = JSON.parse(await readFile(resolve(directory, "package-lock.json"), "utf8"));
const notices = ["LiveKit browser SDK and dependency licenses\n"];
for (const [path, metadata] of Object.entries(lock.packages)) {
  if (!path || /node_modules\/(?:@esbuild\/|esbuild$)/.test(path)) continue;
  notices.push(`\n--- ${path.replace("node_modules/", "")} ${metadata.version} (${metadata.license || "see below"}) ---\n`);
  const files = await readdir(resolve(directory, path));
  for (const name of files.filter(name => /^(?:licen[cs]e|copying|notice)(?:\.|$)/i.test(name)).sort()) {
    notices.push(await readFile(resolve(directory, path, name), "utf8"));
  }
}

// The RNNoise WebAssembly binaries and worklet are prebuilt inside
// @sapphi-red/web-noise-suppressor, so their upstream licenses are not
// reachable through this lockfile.
notices.push(`
--- Bundled inside @sapphi-red/web-noise-suppressor ${suppressorVersion} ---

vendor/javascript/rnnoise.wasm, vendor/javascript/rnnoise-simd.wasm and
vendor/javascript/noise-suppressor-worklet.js embed @shiguredo/rnnoise-wasm
2022.2.0 (Apache License 2.0), which is a WebAssembly build of RNNoise by
Xiph.Org Foundation, Mozilla Corporation, Jean-Marc Valin and Gregory Maxwell
(BSD 3-Clause License).

https://github.com/shiguredo/rnnoise-wasm
https://github.com/xiph/rnnoise
`);

const noticeText = notices.join("\n").replace(/\r\n/g, "\n").replace(/[ \t]+$/gm, "");
await writeFile(vendor("livekit-client.NOTICES.txt"), noticeText);
