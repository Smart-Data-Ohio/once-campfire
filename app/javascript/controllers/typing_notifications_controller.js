import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"
import { throttle } from "helpers/timing_helpers"
import { pageIsTurboPreview } from "helpers/turbo_helpers"
import TypingTracker from "models/typing_tracker"

export default class extends Controller {
  static targets = [ "author", "indicator" ]
  static classes = [ "active" ]
  static values = { roomId: Number, threadId: Number }

  #connectionToken = 0

  async connect() {
    if (!pageIsTurboPreview()) {
      const connectionToken = ++this.#connectionToken
      this.tracker = new TypingTracker(this.#update.bind(this))
      const parameters = {
        channel: "TypingNotificationsChannel",
        room_id: this.hasRoomIdValue ? this.roomIdValue : Current.room.id,
      }
      if (this.hasThreadIdValue && this.threadIdValue > 0) parameters.thread_id = this.threadIdValue

      const channel = await cable.subscribeTo(
        parameters,
        { received: this.#received.bind(this) }
      )
      if (this.#connectionToken === connectionToken && this.element.isConnected) {
        this.channel = channel
      } else {
        channel.unsubscribe()
      }
    }
  }

  disconnect() {
    this.#connectionToken++
    this.tracker?.close()
    this.channel?.unsubscribe()
    this.channel = null
  }

  start({ target }) {
    if (target.value) {
      this.#throttledSend("start")
    } else {
      this.#send("stop")
    }
  }

  stop() {
    this.#send("stop");
  }

  #received({ action, user }) {
    if (user.id !== Current.user.id) {
      if (action === "start") {
        this.tracker.add(user.name)
      } else {
        this.tracker.remove(user.name)
      }
    }
  }

  #send(action) {
    this.channel?.send({ action })
  }

  #update(message) {
    this.authorTarget.textContent = message
    this.indicatorTarget.classList.toggle(this.activeClass, !!message)
  }

  #throttledSend = throttle(action => this.#send(action))
}
