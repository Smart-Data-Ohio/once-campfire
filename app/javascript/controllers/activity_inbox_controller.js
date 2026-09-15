import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"
import { pageIsTurboPreview } from "helpers/turbo_helpers"

const REFRESH_AFTER_HIDDEN_TIMEOUT = 60_000

export default class extends Controller {
  static values = { url: String }

  #active = false
  #generation = null
  #refreshPending = false
  #refreshDirty = false
  #refreshAbortController = null
  #hiddenAt = null

  async connect() {
    if (pageIsTurboPreview()) return

    this.#active = true
    document.addEventListener("visibilitychange", this.#visibilityChanged)
    window.addEventListener("online", this.#online)

    const generation = this.#generation = Symbol()
    try {
      const channel = await cable.subscribeTo({ channel: "ActivityChannel" }, {
        connected: () => this.#withCurrentGeneration(generation, this.#channelConnected),
        received: () => this.#withCurrentGeneration(generation, this.#activityReceived),
      })

      if (!this.#active || this.#generation !== generation) {
        channel.unsubscribe()
      } else {
        this.channel = channel
      }
    } catch {
      // A later visibility or online event can retry through the shared
      // Action Cable connection without making the inbox page noisy.
    }
  }

  disconnect() {
    this.#active = false
    this.#generation = Symbol()
    this.#cancelRefresh()
    document.removeEventListener("visibilitychange", this.#visibilityChanged)
    window.removeEventListener("online", this.#online)
    this.channel?.unsubscribe()
    this.channel = null
  }

  urlValueChanged() {
    if (!this.#active) return

    this.#cancelRefresh()
    this.#refresh()
  }

  #channelConnected = () => {
    this.#refresh()
  }

  #activityReceived = () => {
    this.#refresh()
  }

  #visibilityChanged = () => {
    if (document.visibilityState === "hidden") {
      this.#hiddenAt = Date.now()
    } else {
      const wasHiddenLongEnough = this.#hiddenAt && Date.now() - this.#hiddenAt > REFRESH_AFTER_HIDDEN_TIMEOUT
      this.#hiddenAt = null
      if (this.#refreshDirty || wasHiddenLongEnough) this.#refresh()
    }
  }

  #online = () => {
    this.#refresh()
  }

  #withCurrentGeneration(generation, callback) {
    if (this.#active && this.#generation === generation) callback()
  }

  #refresh() {
    if (!this.#active) return

    this.#refreshDirty = true
    this.#startRefresh()
  }

  #startRefresh() {
    if (!this.#active || this.#refreshPending || document.visibilityState === "hidden" || !this.#refreshDirty) return

    this.#refreshDirty = false
    this.#refreshPending = true
    const requestGeneration = this.#generation
    const abortController = this.#refreshAbortController = new AbortController()
    let succeeded = false

    fetch(this.urlValue, {
      headers: { Accept: "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" },
      cache: "no-store",
      credentials: "same-origin",
      signal: abortController.signal,
    })
      .then(async response => {
        if (!this.#currentRefresh(requestGeneration, abortController)) return
        if (!response.ok || !response.headers.get("content-type")?.includes("turbo-stream")) {
          this.#refreshDirty = true
          return
        }

        const stream = await response.text()
        if (!this.#currentRefresh(requestGeneration, abortController)) return

        Turbo.renderStreamMessage(stream)
        succeeded = true
      })
      .catch(error => {
        if (error.name !== "AbortError" && this.#currentRefresh(requestGeneration, abortController)) this.#refreshDirty = true
      })
      .finally(() => {
        if (!this.#active || this.#generation !== requestGeneration || this.#refreshAbortController !== abortController) return

        this.#refreshPending = false
        this.#refreshAbortController = null
        if (succeeded) this.#startRefresh()
      })
  }

  #currentRefresh(requestGeneration, abortController) {
    return this.#active && this.#generation === requestGeneration && this.#refreshAbortController === abortController && !abortController.signal.aborted
  }

  #cancelRefresh() {
    this.#refreshAbortController?.abort()
    this.#refreshAbortController = null
    this.#refreshPending = false
  }
}
