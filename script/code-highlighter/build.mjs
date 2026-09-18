import { build } from "esbuild"
import { readFile, readdir, writeFile } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const directory = dirname(fileURLToPath(import.meta.url))
const vendor = name => resolve(directory, "../../vendor/javascript", name)

await build({
  absWorkingDir: directory,
  entryPoints: [ "worker.mjs" ],
  outfile: vendor("code-highlighter-worker.js"),
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  minify: true,
  legalComments: "eof",
  banner: { js: "// Shiki 4.4.3 + Highlight.js 11.9.0 language detection. Rebuild in script/code-highlighter with npm ci && npm run build." }
})

const lock = JSON.parse(await readFile(resolve(directory, "package-lock.json"), "utf8"))
const notices = [ "Smartfire code highlighter and dependency licenses\n" ]
for (const [path, metadata] of Object.entries(lock.packages)) {
  if (!path || /node_modules\/(?:@esbuild\/|esbuild$)/.test(path)) continue
  notices.push(`\n--- ${path.replace("node_modules/", "")} ${metadata.version} (${metadata.license || "see below"}) ---\n`)
  const files = await readdir(resolve(directory, path))
  for (const name of files.filter(name => /^(?:licen[cs]e|copying|notice)(?:\.|$)/i.test(name)).sort()) {
    notices.push(await readFile(resolve(directory, path, name), "utf8"))
  }
}
notices.push("\n--- Highlight.js 11.9.0 (language detection) ---\n", await readFile(vendor("highlight.js/LICENSE"), "utf8"))
await writeFile(vendor("code-highlighter.NOTICES.txt"), notices.join("\n").replace(/\r\n/g, "\n").replace(/[ \t]+$/gm, ""))
