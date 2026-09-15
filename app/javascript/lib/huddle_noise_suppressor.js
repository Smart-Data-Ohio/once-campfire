// RNNoise microphone noise suppression for huddles.
//
// LiveKit Cloud's Krisp filter is not available to a self-hosted deployment, so
// Campfire runs RNNoise itself as a LiveKit audio `TrackProcessor`. The model
// runs in an AudioWorklet, which keeps it off the main thread, and the WebAssembly
// module is shipped from this origin rather than a CDN.
//
// RNNoise is trained for 48 kHz mono speech. When the browser hands LiveKit an
// AudioContext at another rate we open a dedicated 48 kHz context instead of
// feeding the model the wrong sample rate.

const RNNOISE_SAMPLE_RATE = 48_000
const PROCESSOR_NAME = "campfire-rnnoise"

let suppressorPromise
let wasmPromise
const contextsWithWorklet = new WeakSet()

const loadSuppressor = () => suppressorPromise ||= import("noise-suppressor").catch(error => {
  suppressorPromise = null
  throw error
})

export const noiseSuppressionSupported = () =>
  typeof AudioWorkletNode === "function" &&
  typeof AudioContext === "function" &&
  typeof WebAssembly === "object" &&
  typeof WebAssembly.instantiate === "function"

export default class HuddleNoiseSuppressor {
  name = PROCESSOR_NAME

  constructor({ workletUrl, wasmUrl, simdWasmUrl }) {
    if (!workletUrl || !wasmUrl || !simdWasmUrl) throw new Error("missing-noise-suppressor-assets")
    if (!noiseSuppressionSupported()) throw new Error("noise-suppression-unsupported")

    this.workletUrl = workletUrl
    this.wasmUrl = wasmUrl
    this.simdWasmUrl = simdWasmUrl
  }

  async init(options) {
    try {
      await this.#start(options)
    } catch (error) {
      // A half-built graph would leave the microphone silent, so unwind before
      // reporting the failure to LiveKit.
      await this.destroy()
      throw error
    }
  }

  async restart(options) {
    await this.destroy()
    await this.init(options)
  }

  async destroy() {
    try {
      this.node?.destroy()
    } catch (error) {
      // The worklet is already gone when its context was closed first.
    }

    this.source?.disconnect()
    this.node?.disconnect()
    // LiveKit stops the track it publishes, not the one this destination owns,
    // so stop it here rather than leaving the graph's output track live.
    this.processedTrack?.stop()
    this.source = null
    this.node = null
    this.destination = null
    this.processedTrack = null

    const ownContext = this.ownContext
    this.ownContext = null
    if (ownContext && ownContext.state !== "closed") await ownContext.close().catch(() => {})
  }

  async #start({ track, audioContext }) {
    const { RnnoiseWorkletNode, loadRnnoise } = await loadSuppressor()
    const context = this.#context(audioContext)

    if (context.state === "suspended") await context.resume().catch(() => {})
    // A context that never starts would publish a silent track, which is worse
    // than publishing the raw microphone. Fail so `init` unwinds to the raw track.
    if (context.state !== "running") throw new Error("noise-suppression-context-not-running")

    if (!contextsWithWorklet.has(context)) {
      await context.audioWorklet.addModule(this.workletUrl)
      contextsWithWorklet.add(context)
    }

    // The binary is structured-cloned into the worklet, so one fetch serves
    // every microphone restart for the life of the page.
    wasmPromise ||= loadRnnoise({ url: this.wasmUrl, simdUrl: this.simdWasmUrl }).catch(error => {
      wasmPromise = null
      throw error
    })
    const wasmBinary = await wasmPromise

    const channelCount = Math.min(Math.max(track.getSettings?.().channelCount || 1, 1), 2)

    this.source = context.createMediaStreamSource(new MediaStream([ track ]))
    this.node = new RnnoiseWorkletNode(context, { maxChannels: channelCount, wasmBinary: wasmBinary.slice(0) })
    this.destination = context.createMediaStreamDestination()
    this.destination.channelCount = channelCount

    this.source.connect(this.node)
    this.node.connect(this.destination)

    const [ processedTrack ] = this.destination.stream.getAudioTracks()
    if (!processedTrack) throw new Error("noise-suppression-produced-no-track")
    this.processedTrack = processedTrack
  }

  #context(audioContext) {
    if (audioContext?.sampleRate === RNNOISE_SAMPLE_RATE && audioContext.state !== "closed") {
      return audioContext
    }

    this.ownContext = new AudioContext({ sampleRate: RNNOISE_SAMPLE_RATE, latencyHint: "interactive" })
    return this.ownContext
  }
}
