import { test } from "node:test"
import assert from "node:assert/strict"
import { highlight } from "./highlighter.mjs"

const samples = {
  bash: 'echo "$HOME"', c: 'int main(void) { return 0; }', cpp: 'template<typename T> class Example {};',
  csharp: 'public class Example { public string Name => "Sam"; }', css: 'body { color: red; }',
  diff: '@@ -1 +1 @@\n-old\n+new', dockerfile: 'FROM ruby:3.4', go: 'func main() { return }',
  html: '<img onerror="alert(1)">', java: 'public class Example { public int value = 1; }',
  javascript: 'const value = true;', json: '{"value": true}', jsx: 'const App = () => <div>Hello</div>;',
  powershell: 'Write-Host "Hello"', python: 'def greet(name): return "Hello " + name',
  ruby: 'def greet(name)\n  puts name\nend', rust: 'fn main() { let value = true; }',
  sql: 'SELECT name FROM users;', typescript: 'const value: string = "hello";',
  tsx: 'const App = () => <div>Hello</div>;', xml: '<root id="1">Hello</root>', yaml: 'enabled: true'
}

for (const [language, source] of Object.entries(samples)) {
  test(`${language} produces theme tokens with exact source offsets`, async () => {
    const { tokens } = await highlight(source, language)
    assert.ok(tokens.length)
    assert.ok(new Set(tokens.map(token => token.variants.dark.color)).size > 1)
    for (const token of tokens) {
      assert.equal(source.slice(token.offset, token.offset + token.content.length), token.content)
      assert.match(token.variants.light.color, /^#[\da-f]{6,8}$/i)
    }
  })
}

test("VS Code Dark+ and Light+ keyword, type and string colors", async () => {
  const { tokens } = await highlight('const value: string = "hello";', "ts")
  for (const [content, light, dark] of [
    [ "const", "#0000FF", "#569CD6" ], [ "string", "#267F99", "#4EC9B0" ], [ '"hello"', "#A31515", "#CE9178" ]
  ]) {
    const token = tokens.find(token => token.content === content)
    assert.equal(token.variants.light.color, light)
    assert.equal(token.variants.dark.color, dark)
  }
})

test("aliases resolve to their precise grammar including C# and C++", async () => {
  for (const [alias, expected] of Object.entries({ "c#": "csharp", "c++": "cpp", TS: "typescript", tsx: "tsx", jsx: "jsx", yml: "yaml", sh: "shellscript" })) {
    assert.equal((await highlight("const value = true;", alias)).language, expected)
  }
})

test("unlabelled code is detected while explicit unknown and text fences stay plain", async () => {
  assert.ok((await highlight(samples.python)).tokens.length)
  for (const language of [ "text", "txt", "plaintext", "unknown", "__proto__", "constructor" ]) {
    assert.deepEqual(await highlight(samples.javascript, language), { language: "text", tokens: [] })
  }
})

test("tabs CRLF blank lines and Unicode stay exact", async () => {
  const source = '\tconst emoji = "🔥";\r\n\r\n// café\r\n'
  const { tokens } = await highlight(source, "javascript")
  for (const token of tokens) assert.equal(source.slice(token.offset, token.offset + token.content.length), token.content)
})
