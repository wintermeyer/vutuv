// Shared plumbing for the classic-page (non-LiveView) progressive enhancements
// in this app (toasts, tag votes, map links, passkeys, the ad banner, …). These
// helpers live here once so each enhancement stays small and the CSRF token,
// page-lifecycle and fetch boilerplate is written a single time instead of being
// copy-pasted into every feature.

// The CSRF token the root layout renders into <meta name="csrf-token">. A getter
// (not a captured value) so it is read at call time — robust if the meta tag is
// ever swapped by a live navigation.
export const csrfToken = () =>
  document.querySelector("meta[name='csrf-token']")?.getAttribute("content")

// Run `fn` once the DOM is parsed AND again after every LiveView navigation
// (phx:page-loading-stop), so a DOM-scanning enhancer also catches markup the
// live shell swaps in. The app bundle is `defer`red, so by the time this runs
// the document is already parsed; we still register for DOMContentLoaded in the
// (theoretical) loading case. `fn` must be safe to run more than once over the
// same nodes — pair it with `once()` when it attaches listeners.
export function onReady(fn) {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", fn)
  } else {
    fn()
  }
  window.addEventListener("phx:page-loading-stop", fn)
}

// Run `fn` when the browser has nothing better to do, for speculative work that
// must never compete with the page it is speculating about. Returns a handle for
// cancelIdle(). Safari has no requestIdleCallback, so it falls back to a timeout
// long enough to be clear of the first paint and the LiveView connect.
export function whenIdle(fn, timeout = 3000) {
  if (typeof requestIdleCallback === "function") {
    return { idle: requestIdleCallback(fn, { timeout }) }
  }

  return { timer: setTimeout(fn, 1500) }
}

export function cancelIdle(handle) {
  if (!handle) return
  if (handle.idle !== undefined && typeof cancelIdleCallback === "function") {
    cancelIdleCallback(handle.idle)
  }
  if (handle.timer !== undefined) clearTimeout(handle.timer)
}

// Whether the member has asked their browser to spend less data (iOS/Safari
// report nothing, which reads as "no"). What it gates here is speculative
// prefetching, never anything the member actually asked for: on a metered or
// very slow link, work nobody requested is the first thing to drop.
export function savesData() {
  const connection = navigator.connection
  if (!connection) return false

  return (
    connection.saveData === true ||
    ["slow-2g", "2g"].includes(connection.effectiveType)
  )
}

// "Wire this element exactly once" guard. Returns true the first time it sees
// `el` under `key` (and marks it), false every time after, so a re-scan from
// onReady() can't attach a duplicate listener.
export function once(el, key) {
  const flag = `wired_${key}`
  if (el.dataset[flag]) return false
  el.dataset[flag] = "1"
  return true
}

// fetch() with the page CSRF token attached, plus the `x-requested-with` marker
// the controllers look for to answer JSON from the :browser pipeline. No Accept
// header on purpose: `accepts ["html"]` 406s an explicit application/json
// Accept, and the actions answer JSON regardless (fetch's default */* is fine).
export function request(url, opts = {}) {
  return fetch(url, {
    ...opts,
    headers: {
      "x-csrf-token": csrfToken(),
      "x-requested-with": "fetch",
      ...(opts.headers || {}),
    },
  })
}

// POST a JSON body with the CSRF token and resolve the parsed JSON response.
export function postJSON(url, body) {
  return request(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  }).then((resp) => resp.json())
}

// True when the viewer asked for less motion; gate every decorative animation on
// it (the count pop, the FLIP reorder, …).
export const reducedMotion = () =>
  window.matchMedia("(prefers-reduced-motion: reduce)").matches

// base64url <-> ArrayBuffer. Two browser APIs in this app speak ArrayBuffers
// while the wire carries unpadded base64url strings: WebAuthn's
// create/get ceremony (webauthn.js) and `pushManager.subscribe`'s
// `applicationServerKey` (the VAPID key, issue #1729). Written once here
// rather than a second time beside whichever one came later.
export function b64urlToBuf(value) {
  const b64 = value.replace(/-/g, "+").replace(/_/g, "/")
  const pad = b64.length % 4 === 0 ? "" : "=".repeat(4 - (b64.length % 4))
  const bin = atob(b64 + pad)
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
  return bytes.buffer
}

export function bufToB64url(buf) {
  const bytes = new Uint8Array(buf)
  let bin = ""
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i])
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

// localStorage, wrapped. A private window, or a browser set to block site data,
// throws on plain access — so every read answers null and every write is a
// no-op rather than taking an unrelated feature down with it. That failure mode
// is reasoned about once, here, instead of in each `try {}` at a call site.
export function localGet(key) {
  try {
    return window.localStorage.getItem(key)
  } catch (_e) {
    return null
  }
}

// A null (or undefined) value forgets the key, which is what every caller here
// means by "no longer true".
export function localSet(key, value) {
  try {
    if (value == null) window.localStorage.removeItem(key)
    else window.localStorage.setItem(key, value)
  } catch (_e) {}
}
