// Live microphone level meter for huddles.
//
// The SDK's `createAudioAnalyser` builds an `AnalyserNode` over the microphone
// track in its own `AudioContext` and reports a frequency-domain volume. The
// server-driven `audioLevel` was the alternative, but it only moves while the
// server counts somebody as speaking, so it cannot drive a meter at rest. This
// polls the analyser at roughly 10 Hz instead, which is smooth enough for a
// small bar and cheap enough to leave running for a whole call.
//
// The analyser owns its AudioContext, so `stop` closes that context again. The
// controller stops the meter on mute, on device switches (which replace the
// underlying track), and on leave; nothing here outlives the call.

const METER_INTERVAL_MS = 100

// `calculateVolume` returns frequency-domain energy, which sits well below 1
// for ordinary speech. The gain maps conversational level onto the top half of
// a 0–100 meter without pinning it on every loud syllable.
const METER_GAIN = 250

export const scaleMeterVolume = (volume) => {
  if (!Number.isFinite(volume) || volume <= 0) return 0
  return Math.min(100, Math.round(volume * METER_GAIN))
}

export default class HuddleMicrophoneMeter {
  constructor(createAudioAnalyser, onLevel) {
    this.createAudioAnalyser = createAudioAnalyser
    this.onLevel = onLevel
    this.analyser = null
    this.timer = null
    this.lastVolume = 0
  }

  get running() {
    return Boolean(this.timer)
  }

  get contextState() {
    return this.analyser?.analyser?.context?.state
  }

  // `track` is the SDK audio track, or `{ mediaStreamTrack }` for a pre-join
  // preview stream, which the analyser only touches through that property.
  start(track) {
    this.stop()

    const mediaStreamTrack = track?.mediaStreamTrack || track?.track?.mediaStreamTrack
    if (!mediaStreamTrack || mediaStreamTrack.readyState !== "live") return

    try {
      this.analyser = this.createAudioAnalyser(track?.mediaStreamTrack ? track : { mediaStreamTrack })
    } catch (error) {
      return
    }

    const poll = () => {
      let volume = 0
      try {
        volume = this.analyser.calculateVolume()
      } catch (error) {
        // A torn-down track reads as silence until the controller restarts us.
      }
      this.lastVolume = volume
      this.onLevel(scaleMeterVolume(volume))
    }

    poll()
    this.timer = setInterval(poll, METER_INTERVAL_MS)
  }

  stop() {
    clearInterval(this.timer)
    this.timer = null
    this.lastVolume = 0

    const analyser = this.analyser
    this.analyser = null
    // Closing the context is what frees the microphone tap; a failure here
    // only means there is nothing left to free.
    if (analyser) Promise.resolve(analyser.cleanup()).catch(() => {})
  }
}
