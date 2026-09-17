import { escapeHTML } from "helpers/string_helpers"

const EMOJI_MATCHER = /^((\p{Emoji_Presentation}|\p{Extended_Pictographic}|\uFE0F)|(:[a-z0-9_]+:))+$/gu

const SOUND_NAMES = [ "56k", "ballmer", "bell", "bezos", "bueller", "butts", "clowntown", "cottoneyejoe", "crickets", "curb", "dadgummit", "dangerzone", "danielsan", "deeper", "donotwant", "drama", "flawless", "glados", "gogogo", "greatjob", "greyjoy", "guarantee", "heygirl", "honk", "horn", "horror", "inconceivable", "letitgo", "live", "loggins", "makeitso", "noooo", "nyan", "ohmy", "ohyeah", "pushit", "rimshot", "rollout", "rumble", "sax", "secret", "sexyback", "story", "tada", "tmyk", "totes", "trololo", "trombone", "unix", "vuvuzela", "what", "whoomp", "wups", "yay", "yeah", "yodel" ]

export default class ClientMessage {
  #template

  constructor(template) {
    this.#template = template
  }

  render(clientMessageId, node) {
    const now = new Date()
    const body = this.#contentFromNode(node)
    const text = this.#plainText(node)

    return this.#createFromTemplate({
      clientMessageId,
      body,
      messageTimestamp: Math.floor(now.getTime()),
      messageDatetime: now.toISOString(),
      messageClasses: this.#containsOnlyEmoji(text) ? "message--emoji" : "",
    })
  }

  update(clientMessageId, body) {
    const element = this.#findWithId(clientMessageId).querySelector(".message__body-content")

    if (element) {
      element.innerHTML = body
    }
  }

  failed(clientMessageId) {
    const element = this.#findWithId(clientMessageId)

    if (element) {
      element.classList.add("message--failed")
      if (element.querySelector(".message__recover-draft")) return

      const recovery = document.createElement("button")
      recovery.type = "button"
      recovery.className = "message__recover-draft btn btn--borderless txt-small"
      recovery.dataset.action = "messages#recoverPendingMessage"
      recovery.dataset.clientMessageId = clientMessageId
      recovery.textContent = "Restore draft"
      element.querySelector(".message__body-content")?.append(recovery)
    }
  }

  #findWithId(clientMessageId) {
    return document.querySelector(`#message_${clientMessageId}`)
  }

  #contentFromNode(node) {
    if (this.#isPlayCommand(node)) {
      return `<span class="pending">Playing ${this.#matchPlayCommand(node)}…</span>`
    } else if (this.#isRichText(node)) {
      return this.#richTextContent(node)
    } else if (node instanceof HTMLTextAreaElement) {
      return `<div class="markdown-body markdown-body--pending">${escapeHTML(node.value)}</div>`
    } else {
      return node
    }
  }


  #isPlayCommand(node) {
    return this.#matchPlayCommand(node)
  }

  #matchPlayCommand(node) {
    return this.#plainText(node)?.trim().match(new RegExp(`^/play (${SOUND_NAMES.join("|")})$`))?.[1]
  }

  #plainText(node) {
    if (node instanceof HTMLTextAreaElement) return node.value
    if (typeof node === "string") return ""
    return node.textContent
  }


  #isRichText(node) {
    return node instanceof HTMLElement && node.tagName === "TRIX-EDITOR"
  }

  #richTextContent(node) {
    return `<div class="trix-content">${node.innerHTML}</div>`
  }


  #createFromTemplate(data) {
    return this.#template.innerHTML.replace(
      /\$(clientMessageId|body|messageTimestamp|messageDatetime|messageClasses)\$/g,
      (_placeholder, key) => data[key]
    )
  }

  #containsOnlyEmoji(text) {
    return text?.match(EMOJI_MATCHER)
  }
}
