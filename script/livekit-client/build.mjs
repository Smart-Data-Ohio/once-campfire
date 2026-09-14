import { build } from "esbuild";
import { readFile, readdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const directory = dirname(fileURLToPath(import.meta.url));
const output = resolve(directory, "../../vendor/javascript/livekit-client.js");
const sdk = JSON.parse(await readFile(resolve(directory, "node_modules/livekit-client/package.json"), "utf8"));

await build({
  absWorkingDir: directory,
  stdin: { contents: 'export * from "livekit-client";', resolveDir: directory },
  outfile: output,
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  minify: true,
  legalComments: "eof",
  banner: { js: `// LiveKit browser SDK ${sdk.version}. Regenerate with npm ci && npm run build in script/livekit-client.` },
});

const license = await readFile(resolve(directory, "node_modules/livekit-client/LICENSE"), "utf8");
await writeFile(resolve(directory, "../../vendor/javascript/livekit-client.LICENSE.txt"), license);

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
const noticeText = notices.join("\n").replace(/\r\n/g, "\n").replace(/[ \t]+$/gm, "");
await writeFile(resolve(directory, "../../vendor/javascript/livekit-client.NOTICES.txt"), noticeText);
