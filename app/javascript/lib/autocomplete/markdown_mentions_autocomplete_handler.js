import BaseAutocompleteHandler from "lib/autocomplete/base_autocomplete_handler"
import { PUNCTUATION_PATTERN } from "lib/autocomplete/constants"
import { escapeHTML } from "helpers/string_helpers"

export default class MarkdownMentionsAutocompleteHandler extends BaseAutocompleteHandler {
  get pattern() {
    return new RegExp(`^@(.*?)(${PUNCTUATION_PATTERN.source}*)$`)
  }

  insertAutocompletable(autocompletable, range, terminator) {
    if (!autocompletable?.mention_token) return

    const replacement = `${autocompletable.mention_token}${terminator}`
    this.element.setRangeText(replacement, range[0], range[1], "end")
    this.element.dispatchEvent(new Event("input", { bubbles: true }))
  }

  fetchResultsForQuery(query, callback) {
    this.loadAutocompletables(query, () => {
      const autocompletables = this.autocompletablesMatchingQuery(query)
      callback(this.#renderSuggestions(autocompletables))
    })
  }

  didShowResults(selectElement) {
    selectElement.classList.add("markdown-autocomplete")
  }

  #renderSuggestions(autocompletables) {
    return autocompletables.map(user => {
      const name = escapeHTML(user.markdown_display_name)
      const avatarUrl = escapeHTML(user.avatar_url)

      if (!user.mention_token) {
        return `
          <div class="autocomplete__item autocomplete__item--disabled flex align-center gap unpad" role="note">
            <span class="avatar"><img src="${avatarUrl}" role="presentation"></span>
            <span class="min-width flex-item-grow"><span class="autocompletable__name">${name}</span><small>Duplicate name — type as plain text</small></span>
          </div>
        `
      }

      return `
        <suggestion-option class="autocomplete__item flex align-center gap unpad" role="option" value="${escapeHTML(user.value)}">
          <button type="button" class="autocomplete__btn btn btn--borderless btn--transparent min-width flex-item-grow justify-start">
            <span class="avatar"><img src="${avatarUrl}" role="presentation"></span>
            <span class="autocompletable__name">${name}</span>
          </button>
        </suggestion-option>
      `
    }).join("")
  }
}
