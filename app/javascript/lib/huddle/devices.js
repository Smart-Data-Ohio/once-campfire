// Huddle device preferences and enumeration.
//
// The chosen microphone, speaker, and camera are remembered per browser in
// `campfire.huddle.devices` and reapplied on the next join when the device is
// still present. Anything missing falls back to the browser default silently.

export const DEVICE_STORAGE_KEY = "campfire.huddle.devices"

const KINDS = [ "audioinput", "audiooutput", "videoinput" ]

const blankPreferences = () => ({ audioinput: "", audiooutput: "", videoinput: "" })

export const loadDevicePreferences = () => {
  try {
    const parsed = JSON.parse(window.localStorage.getItem(DEVICE_STORAGE_KEY) || "{}")
    const preferences = blankPreferences()

    for (const kind of KINDS) {
      if (typeof parsed[kind] === "string") preferences[kind] = parsed[kind]
    }

    return preferences
  } catch (error) {
    // Private browsing modes can refuse storage; every join then uses defaults.
    return blankPreferences()
  }
}

export const storeDevicePreference = (kind, deviceId) => {
  if (!KINDS.includes(kind)) return

  try {
    const preferences = loadDevicePreferences()
    preferences[kind] = deviceId || ""
    window.localStorage.setItem(DEVICE_STORAGE_KEY, JSON.stringify(preferences))
  } catch (error) {
    // The preference simply does not survive this session.
  }
}

// Plain enumeration, which never triggers a permission prompt. Labels stay
// empty until the page has microphone or camera access; callers fall back to
// numbered names in that case.
export const listMediaDevices = async () => {
  const devices = await navigator.mediaDevices.enumerateDevices()
  const grouped = { audioinput: [], audiooutput: [], videoinput: [] }

  for (const device of devices) {
    if (grouped[device.kind]) grouped[device.kind].push(device)
  }

  return grouped
}

// Output switching needs `setSinkId`, which Safari does not implement. The
// speaker picker is hidden where this is false rather than offering a control
// that can only fail.
export const audioOutputSupported = () =>
  typeof document !== "undefined" && "setSinkId" in document.createElement("audio")

export const deviceLabel = (device, kind, index) => {
  if (device.label) return device.label

  const names = { audioinput: "Microphone", audiooutput: "Speaker", videoinput: "Camera" }
  return `${names[kind] || "Device"} ${index + 1}`
}
