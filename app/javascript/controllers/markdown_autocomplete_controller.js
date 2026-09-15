import { Controller } from "@hotwired/stimulus"
import { debounce } from "helpers/timing_helpers"
import MarkdownMentionsAutocompleteHandler from "lib/autocomplete/markdown_mentions_autocomplete_handler"

export default class extends Controller {
  static values = { url: String }

  initialize() {
    this.search = debounce(this.search.bind(this), 250)
  }

  connect() {
    if (this.element === document.activeElement) this.#installHandler()
  }

  disconnect() {
    this.#uninstallHandler()
  }

  focus() {
    this.#installHandler()
    this.search()
  }

  search() {
    this.handler?.updateWithContentAndPosition(this.element.value, this.element.selectionStart)
  }

  blur() {
    this.#uninstallHandler()
  }

  #installHandler() {
    this.#uninstallHandler()
    this.handler = new MarkdownMentionsAutocompleteHandler(this.element, this.urlValue)
  }

  #uninstallHandler() {
    this.handler?.destroy()
    this.handler = null
  }
}
