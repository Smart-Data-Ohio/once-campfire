// Channel switches should feel like a native app: the current channel stays
// on screen until the next one is ready, with no top progress bar flash.
//
// Turbo Drive already holds the old page until the new one renders; the flash
// is Turbo's progress bar (a fixed 3px bar at the top, shown 500ms after a
// visit starts). Suppress it only for same-origin visits to room pages.
// Frame loads (sidebar, reconnect refreshes), form submissions, and non-room
// visits keep their existing feedback. Error responses still render normally.
const ROOM_PAGE_PATTERN = /^\/rooms\/\d+(?:\/@\d+)?\/?$/
const SUPPRESSED_ATTRIBUTE = "data-channel-navigation"

function isSameOriginRoomPage(url) {
  try {
    const location = new URL(url, window.location.origin)
    return location.origin === window.location.origin && ROOM_PAGE_PATTERN.test(location.pathname)
  } catch {
    return false
  }
}

function suppressProgressBar() {
  document.documentElement.setAttribute(SUPPRESSED_ATTRIBUTE, "")
}

function restoreProgressBar() {
  document.documentElement.removeAttribute(SUPPRESSED_ATTRIBUTE)
}

// Classify accepted visits, including history restores and redirect follow-ups.
// Canceled before-visit events must not leave suppression behind, and frame
// loads never change the current page's navigation state.
document.addEventListener("turbo:visit", (event) => {
  if (isSameOriginRoomPage(event.detail.url)) {
    suppressProgressBar()
  } else {
    restoreProgressBar()
  }
})

// turbo:load fires after every completed visit, including visits that render
// an error page. Network failures reload the document instead, which drops
// the attribute along with the old document.
document.addEventListener("turbo:load", restoreProgressBar)
