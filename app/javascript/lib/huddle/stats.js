// Connection statistics for the huddle details panel.
//
// Everything here is sampled from WebRTC `getStats` reports on demand — the
// publisher report comes from the local microphone track's sender, the
// subscriber report from a subscribed remote track's receiver — and nothing is
// logged or sent to the server. Round-trip time, loss, and jitter describe the
// upstream path (our microphone to the server, as the server reports it back);
// received bitrate describes the subscriber path. See docs/huddle-quality.md
// for exactly what is measured and what is not.

export const summarizeConnectionStats = ({ publisherReport, subscriberReport, previous, now = Date.now() }) => {
  const publisher = readPublisherReport(publisherReport)
  const subscriber = readSubscriberReport(subscriberReport)

  const txBps = bitrate(publisher.bytesSent, previous?.txBytes, now, previous?.at)
  const rxBps = bitrate(subscriber.bytesReceived, previous?.rxBytes, now, previous?.at)

  return {
    rttMs: publisher.rttMs,
    lossRatio: publisher.lossRatio,
    jitterMs: publisher.jitterMs,
    rxBps,
    txBps,
    relayed: publisher.relayed ?? subscriber.relayed,
    previous: { at: now, txBytes: publisher.bytesSent, rxBytes: subscriber.bytesReceived }
  }
}

export const formatConnectionStats = (summary) => ({
  rtt: formatMilliseconds(summary.rttMs),
  loss: formatPercent(summary.lossRatio),
  jitter: formatMilliseconds(summary.jitterMs),
  received: formatBitrate(summary.rxBps),
  sent: formatBitrate(summary.txBps),
  transport: summary.relayed == null ? "–" : summary.relayed ? "Relayed (TURN)" : "Direct"
})

const forEachStat = (report, callback) => {
  if (!report || typeof report.forEach !== "function") return
  report.forEach(callback)
}

const readPublisherReport = (report) => {
  // Audio is the stable track: it is published for the whole call while video
  // comes and goes. Video remote-inbound entries are ignored so the numbers do
  // not jump when a screen share starts or stops.
  let feedback = null
  let fallbackFeedback = null
  let bytesSent = 0
  let pair = null
  let nominatedPair = null
  const candidates = new Map()

  forEachStat(report, (stat) => {
    if (stat.type === "outbound-rtp" && !stat.isRemote && Number.isFinite(stat.bytesSent)) {
      bytesSent += stat.bytesSent
    } else if (stat.type === "remote-inbound-rtp") {
      if (stat.kind === "audio") {
        feedback = stat
      } else if (!fallbackFeedback) {
        fallbackFeedback = stat
      }
    } else if (stat.type === "transport" && stat.selectedCandidatePairId && typeof report.get === "function") {
      pair = report.get(stat.selectedCandidatePairId) || pair
    } else if (stat.type === "candidate-pair") {
      if (stat.nominated || stat.selected) pair = pair || stat
      if (stat.state === "succeeded") nominatedPair = nominatedPair || stat
    } else if (stat.type === "local-candidate" || stat.type === "remote-candidate") {
      candidates.set(stat.id, stat)
    }
  })

  const upstream = feedback || fallbackFeedback
  const selectedPair = pair?.localCandidateId ? pair : nominatedPair

  return {
    rttMs: secondsToMilliseconds(upstream?.roundTripTime),
    lossRatio: lossRatio(upstream?.packetsLost, packetsTotal(upstream)),
    jitterMs: secondsToMilliseconds(upstream?.jitter),
    bytesSent,
    relayed: transportRelayed(selectedPair, candidates, report)
  }
}

const readSubscriberReport = (report) => {
  let bytesReceived = 0
  let pair = null
  let nominatedPair = null
  const candidates = new Map()

  forEachStat(report, (stat) => {
    if (stat.type === "inbound-rtp" && Number.isFinite(stat.bytesReceived)) {
      bytesReceived += stat.bytesReceived
    } else if (stat.type === "transport" && stat.selectedCandidatePairId && typeof report.get === "function") {
      pair = report.get(stat.selectedCandidatePairId) || pair
    } else if (stat.type === "candidate-pair") {
      if (stat.nominated || stat.selected) pair = pair || stat
      if (stat.state === "succeeded") nominatedPair = nominatedPair || stat
    } else if (stat.type === "local-candidate" || stat.type === "remote-candidate") {
      candidates.set(stat.id, stat)
    }
  })

  return {
    bytesReceived,
    relayed: transportRelayed(pair?.localCandidateId ? pair : nominatedPair, candidates, report)
  }
}

const transportRelayed = (pair, candidates, report) => {
  if (!pair) return null

  const local = candidates.get(pair.localCandidateId) || report?.get?.(pair.localCandidateId)
  const remote = candidates.get(pair.remoteCandidateId) || report?.get?.(pair.remoteCandidateId)
  if (!local && !remote) return null

  return local?.candidateType === "relay" || remote?.candidateType === "relay"
}

const packetsTotal = (stat) => {
  if (!stat) return null
  // `packetsSent` lives on the outbound side; some browsers repeat it on the
  // remote-inbound entry, others do not. Without a denominator there is no ratio.
  const sent = stat.packetsSent
  const lost = stat.packetsLost
  if (!Number.isFinite(sent) || !Number.isFinite(lost)) return null
  return sent + lost
}

const lossRatio = (lost, total) => {
  if (!Number.isFinite(lost) || !Number.isFinite(total) || total <= 0) return null
  return Math.min(1, Math.max(0, lost / total))
}

const secondsToMilliseconds = (seconds) =>
  Number.isFinite(seconds) && seconds >= 0 ? seconds * 1000 : null

const bitrate = (bytes, previousBytes, now, previousAt) => {
  if (!Number.isFinite(bytes) || !Number.isFinite(previousBytes) || !Number.isFinite(previousAt)) return null
  const elapsedSeconds = (now - previousAt) / 1000
  if (elapsedSeconds <= 0 || bytes < previousBytes) return null
  return ((bytes - previousBytes) * 8) / elapsedSeconds
}

const formatMilliseconds = (value) => {
  if (!Number.isFinite(value)) return "–"
  return value < 10 ? `${value.toFixed(1)} ms` : `${Math.round(value)} ms`
}

const formatPercent = (value) => {
  if (!Number.isFinite(value)) return "–"
  return `${(value * 100).toFixed(1)}%`
}

const formatBitrate = (value) => {
  if (!Number.isFinite(value)) return "–"
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)} Mbps`
  return `${Math.max(0, Math.round(value / 1000))} kbps`
}
