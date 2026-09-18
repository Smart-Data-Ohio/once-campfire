let worker
let nextId = 0
const pending = new Map()
const highlighting = new WeakSet()

// One lazy worker survives Turbo visits. Loading grammars and tokenizing code
// cannot hold up channel navigation or typing in the composer.
function tokenize(source, language) {
  return new Promise((resolve, reject) => {
    if (!worker) {
      worker = new Worker(import.meta.resolve("code-highlighter-worker"), { type: "module" })
      worker.onmessage = ({ data: { id, result, error } }) => {
        const request = pending.get(id)
        if (!request) return
        clearTimeout(request.timeout)
        pending.delete(id)
        error ? request.reject() : request.resolve(result)
      }
      worker.onerror = stopWorker
      worker.onmessageerror = stopWorker
    }

    const id = ++nextId
    pending.set(id, { resolve, reject, timeout: setTimeout(stopWorker, 15_000) })
    worker.postMessage({ id, source, language })
  })
}

function stopWorker() {
  worker?.terminate()
  worker = null
  for (const request of pending.values()) {
    clearTimeout(request.timeout)
    request.reject()
  }
  pending.clear()
}

export async function highlightCodeBlock(pre) {
  const code = pre.querySelector(":scope > code") || pre
  if (code.dataset.highlighted || highlighting.has(code)) return
  if (!Array.from(code.childNodes).every(node => node.nodeType === Node.TEXT_NODE)) return

  const source = code.textContent
  const language = `${code.className} ${pre.className}`.match(/\blang(?:uage)?-([\w+#.-]+)(?=\s|$)/i)?.[1]
  highlighting.add(code)

  try {
    const result = await tokenize(source, language)
    // An edit or a Turbo visit may have replaced this body while work ran.
    if (!code.isConnected || code.textContent !== source) return

    const fragment = document.createDocumentFragment()
    let offset = 0
    for (const token of result.tokens) {
      fragment.append(document.createTextNode(source.slice(offset, token.offset)))
      const span = document.createElement("span")
      span.className = "code-token"
      span.textContent = token.content
      for (const [theme, style] of Object.entries(token.variants)) {
        span.style.setProperty(`--code-${theme}`, style.color)
        span.style.setProperty(`--code-${theme}-font-style`, style.fontStyle & 1 ? "italic" : "normal")
        span.style.setProperty(`--code-${theme}-font-weight`, style.fontStyle & 2 ? "bold" : "normal")
        span.style.setProperty(`--code-${theme}-decoration`, style.fontStyle & 4 ? "underline" : "none")
      }
      fragment.append(span)
      offset = token.offset + token.content.length
    }
    fragment.append(document.createTextNode(source.slice(offset)))
    if (fragment.textContent !== source) return

    code.replaceChildren(fragment)
    code.dataset.highlighted = "yes"
    code.dataset.codeLanguage = result.language
    pre.classList.add("code-highlighted")
  } catch {
    // Plain code and its copy button remain usable if a worker cannot load.
  } finally {
    highlighting.delete(code)
  }
}
