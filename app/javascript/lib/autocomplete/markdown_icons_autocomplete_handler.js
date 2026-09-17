import BaseAutocompleteHandler from "lib/autocomplete/base_autocomplete_handler"
import { escapeHTML } from "helpers/string_helpers"

export default class MarkdownIconsAutocompleteHandler extends BaseAutocompleteHandler {
  constructor(element, url) {
    super(element, url)
    this.iconsUrl = url
  }

  get pattern() {
    return /^:([a-z0-9_]{2,})$/
  }

  getSuggestionsIdentifier() {
    return `${super.getSuggestionsIdentifier()}_icons`
  }

  insertAutocompletable(autocompletable, range, terminator) {
    if (!autocompletable?.name) return

    const replacement = `:${autocompletable.name}: `
    this.element.setRangeText(replacement, range[0], range[1], "end")
    this.element.dispatchEvent(new Event("input", { bubbles: true }))
  }

  fetchResultsForQuery(query, callback) {
    fetch(this.#autocompletablesUrl(query), { headers: { "Accept": "application/json" } })
      .then(response => response.json())
      .then(icons => {
        this.setAutocompletables(icons)
        callback(this.#renderSuggestions(icons))
      })
      .catch(() => callback(""))
  }

  didShowResults(selectElement) {
    selectElement.classList.add("markdown-autocomplete")
  }

  #autocompletablesUrl(query) {
    return `${this.iconsUrl}?q=${encodeURIComponent(query)}`
  }

  #renderSuggestions(icons) {
    return icons.map(icon => {
      const value = escapeHTML(icon.value)
      const name = escapeHTML(icon.name)

      if (icon.kind === "brand" || icon.kind === "custom") {
        const title = escapeHTML(icon.title)
        const image = escapeHTML(icon.image)
        const iconClass = icon.kind === "brand" ? "icon icon--brand" : "icon icon--custom"

        return `
          <suggestion-option class="autocomplete__item flex align-center gap unpad" role="option" value="${value}">
            <button type="button" class="autocomplete__btn btn btn--borderless btn--transparent min-width flex-item-grow justify-start">
              <span class="autocomplete__icon"><img class="${iconClass}" src="${image}" alt="" role="presentation"></span>
              <span class="autocompletable__name">${title}</span>
              <small class="autocomplete__shortcode">:${name}:</small>
            </button>
          </suggestion-option>
        `
      } else {
        const character = escapeHTML(icon.character)

        return `
          <suggestion-option class="autocomplete__item flex align-center gap unpad" role="option" value="${value}">
            <button type="button" class="autocomplete__btn btn btn--borderless btn--transparent min-width flex-item-grow justify-start">
              <span class="autocomplete__icon" aria-hidden="true">${character}</span>
              <span class="autocompletable__name">:${name}:</span>
            </button>
          </suggestion-option>
        `
      }
    }).join("")
  }
}
