import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

const HEARTBEAT_INTERVAL = 25 * 1000

export default class extends Controller {
  connect() {
    this.active = true
    window.addEventListener("pagehide", this.#pageHidden)
    window.addEventListener("pageshow", this.#pageShown)
    this.#startSubscription()
  }

  disconnect() {
    this.active = false
    window.removeEventListener("pagehide", this.#pageHidden)
    window.removeEventListener("pageshow", this.#pageShown)
    this.#closeSubscription()
  }

  #connected = () => {
    if (!this.active) return

    this.#stopHeartbeat()
    this.heartbeatTimer = setInterval(this.#heartbeat, HEARTBEAT_INTERVAL)
    window.dispatchEvent(new CustomEvent("workspace-presence:connected"))
  }

  #disconnected = () => {
    this.#stopHeartbeat()
  }

  #rejected = () => {
    this.#stopHeartbeat()
  }

  #heartbeat = () => {
    this.channel?.send({ action: "heartbeat" })
  }

  #pageHidden = () => {
    this.#closeSubscription()
  }

  #pageShown = () => {
    if (this.active && !this.channel) this.#startSubscription()
  }

  #stopHeartbeat() {
    clearInterval(this.heartbeatTimer)
    this.heartbeatTimer = null
  }

  async #subscribe(generation) {
    try {
      const channel = await cable.subscribeTo("WorkspacePresenceChannel", {
        connected: () => this.#withCurrentGeneration(generation, this.#connected),
        disconnected: () => this.#withCurrentGeneration(generation, this.#disconnected),
        rejected: () => this.#withCurrentGeneration(generation, this.#rejected)
      })

      if (!this.active || this.generation !== generation) {
        channel.unsubscribe()
      } else {
        this.channel = channel
        this.subscriptionPending = false
      }
    } catch {
      if (this.generation === generation) {
        this.subscriptionPending = false
        this.#stopHeartbeat()
      }
    }
  }

  #withCurrentGeneration(generation, callback) {
    if (this.active && this.generation === generation) callback()
  }

  #startSubscription() {
    if (this.channel || this.subscriptionPending) return

    this.subscriptionPending = true
    const generation = this.generation = Symbol()
    this.#subscribe(generation)
  }

  #closeSubscription() {
    this.generation = Symbol()
    this.subscriptionPending = false
    this.#stopHeartbeat()
    this.channel?.unsubscribe()
    this.channel = null
  }
}
