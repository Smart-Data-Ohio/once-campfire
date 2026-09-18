import { createHighlighterCore } from "shiki/core"
import { createJavaScriptRegexEngine } from "shiki/engine/javascript"
import light from "shiki/themes/light-plus.mjs"
import dark from "shiki/themes/dark-plus.mjs"
import bash from "shiki/langs/shellscript.mjs"
import c from "shiki/langs/c.mjs"
import cpp from "shiki/langs/cpp.mjs"
import csharp from "shiki/langs/csharp.mjs"
import css from "shiki/langs/css.mjs"
import diff from "shiki/langs/diff.mjs"
import docker from "shiki/langs/docker.mjs"
import go from "shiki/langs/go.mjs"
import html from "shiki/langs/html.mjs"
import java from "shiki/langs/java.mjs"
import javascript from "shiki/langs/javascript.mjs"
import json from "shiki/langs/json.mjs"
import jsx from "shiki/langs/jsx.mjs"
import powershell from "shiki/langs/powershell.mjs"
import python from "shiki/langs/python.mjs"
import ruby from "shiki/langs/ruby.mjs"
import rust from "shiki/langs/rust.mjs"
import sql from "shiki/langs/sql.mjs"
import typescript from "shiki/langs/typescript.mjs"
import tsx from "shiki/langs/tsx.mjs"
import xml from "shiki/langs/xml.mjs"
import yaml from "shiki/langs/yaml.mjs"
import detector from "./detector.mjs"

const grammars = [ bash, c, cpp, csharp, css, diff, docker, go, html, java, javascript, json, jsx, powershell, python, ruby, rust, sql, typescript, tsx, xml, yaml ]
const aliases = { bash: "shellscript", sh: "shellscript", shell: "shellscript", zsh: "shellscript", "c#": "csharp", cs: "csharp", "c++": "cpp", dockerfile: "docker", ps1: "powershell" }
for (const grammar of grammars.flat()) {
  aliases[grammar.name] = grammar.name
  for (const alias of grammar.aliases || []) aliases[alias] = grammar.name
}

let highlighter

export async function highlight(source, label) {
  // Unknown explicit labels and text fences must never trigger guessing.
  const detected = label ? label.toLowerCase() : detector.highlightAuto(source).language
  const language = Object.hasOwn(aliases, detected) ? aliases[detected] : null
  if (!language) return { language: "text", tokens: [] }

  highlighter ||= createHighlighterCore({ langs: grammars, themes: [ light, dark ], engine: createJavaScriptRegexEngine() })
  const engine = await highlighter
  const tokens = engine.codeToTokensWithThemes(source, {
    lang: language, themes: { light: "light-plus", dark: "dark-plus" }
  }).flat()

  return { language, tokens }
}
