import { Controller } from "@hotwired/stimulus"
import { debounce } from "helpers/timing_helpers"
import MarkdownMentionsAutocompleteHandler from "lib/autocomplete/markdown_mentions_autocomplete_handler"
import MarkdownIconsAutocompleteHandler from "lib/autocomplete/markdown_icons_autocomplete_handler"

export default class extends Controller {
  static values = { url: String, iconsUrl: String }

  initialize() {
    this.search = debounce(this.search.bind(this), 250)
  }

  connect() {
    if (this.element === document.activeElement) this.#installHandlers()
  }

  disconnect() {
    this.#uninstallHandlers()
  }

  focus() {
    this.#installHandlers()
    this.search()
  }

  search() {
    this.handlers?.forEach(handler => {
      handler.updateWithContentAndPosition(this.element.value, this.element.selectionStart)
    })
  }

  blur() {
    this.#uninstallHandlers()
  }

  #installHandlers() {
    this.#uninstallHandlers()
    this.handlers = []

    if (this.hasUrlValue) {
      this.handlers.push(new MarkdownMentionsAutocompleteHandler(this.element, this.urlValue))
    }

    if (this.hasIconsUrlValue) {
      this.handlers.push(new MarkdownIconsAutocompleteHandler(this.element, this.iconsUrlValue))
    }
  }

  #uninstallHandlers() {
    this.handlers?.forEach(handler => handler.destroy())
    this.handlers = null
  }
}
