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
  // Null until an outbound entry is seen: a failed report must read as "no
  // sample", not as zero bytes, or the next bitrate spikes off a zero base.
  let bytesSent = null
  let audioPacketsSent = null
  let totalPacketsSent = 0
  let packetsSentSeen = false
  let pair = null
  let nominatedPair = null
  const candidates = new Map()

  forEachStat(report, (stat) => {
    if (stat.type === "outbound-rtp" && !stat.isRemote) {
      if (Number.isFinite(stat.bytesSent)) bytesSent = (bytesSent || 0) + stat.bytesSent
      // Chrome does not repeat `packetsSent` on the remote-inbound entry, so
      // the loss denominator comes from the outbound side of the same flow.
      if (Number.isFinite(stat.packetsSent)) {
        packetsSentSeen = true
        totalPacketsSent += stat.packetsSent
        if (stat.kind === "audio") audioPacketsSent = (audioPacketsSent || 0) + stat.packetsSent
      }
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
  const sent = upstream?.kind === "audio"
    ? (audioPacketsSent ?? (packetsSentSeen ? totalPacketsSent : null))
    : (packetsSentSeen ? totalPacketsSent : null)
  const total = sent == null || !Number.isFinite(upstream?.packetsLost) ? null : sent + upstream.packetsLost

  return {
    rttMs: secondsToMilliseconds(upstream?.roundTripTime),
    lossRatio: lossRatio(upstream?.packetsLost, total),
    jitterMs: secondsToMilliseconds(upstream?.jitter),
    bytesSent,
    relayed: transportRelayed(selectedPair, candidates, report)
  }
}

const readSubscriberReport = (report) => {
  // Same "no sample" rule as the publisher side: nothing subscribed to reads
  // as unknown, not as zero, so a later subscription never spikes.
  let bytesReceived = null
  let pair = null
  let nominatedPair = null
  const candidates = new Map()

  forEachStat(report, (stat) => {
    if (stat.type === "inbound-rtp" && Number.isFinite(stat.bytesReceived)) {
      bytesReceived = (bytesReceived || 0) + stat.bytesReceived
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
