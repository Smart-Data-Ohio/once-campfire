import { highlight } from "./highlighter.mjs"

self.onmessage = async ({ data: { id, source, language } }) => {
  try {
    self.postMessage({ id, result: await highlight(source, language) })
  } catch {
    self.postMessage({ id, error: true })
  }
}
