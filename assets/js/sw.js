// vutuv's service worker (issue #1729).
//
// Hand-written and deliberately small. Workbox would buy nothing at this size
// and would hide the caching rules, which is precisely where the danger is.
//
// It is NOT bundled by esbuild and NOT served from /assets: a worker's scope is
// the directory it is served from, and only a worker at the root can control
// the whole site. `VutuvWeb.ServiceWorkerController` serves this file verbatim
// at /sw.js with one configuration object prepended (see CONFIG below), which
// is also what gives it a version to key its cache on.
//
// THE LOAD-BEARING DECISION IS: NEVER CACHE HTML. A cached page carries a
// stale CSRF token and whoever was signed in when it was stored, and the
// LiveView socket would join against a document the server never sent. Only
// `/assets/*` is cached — those filenames carry a content digest, so they are
// immutable — plus the one offline page. Everything else goes to the network
// untouched. Full offline is not a goal and would be the wrong investment for
// a real-time social site; an offline page instead of the browser's dinosaur
// is one file.

// Defaults so this file is valid and testable on its own; the server prepends
// the real values.
const CONFIG = self.VUTUV_SW_CONFIG || {
  version: "dev",
  // Off wherever assets are served undigested (dev, test): a cache-first rule
  // over `/assets/app.js` would serve yesterday's bundle after a rebuild.
  cacheAssets: false,
  offlineUrl: "/system/offline",
  icon: "/images/icon-192.png",
  // kind -> locale -> line. Generic on purpose: see the push handler.
  strings: {},
  fallbackLocale: "en",
}

const CACHE = `vutuv-${CONFIG.version}`

// The offline page is the one document that may be stored, and it is written
// for it: no session, no CSRF token, nothing that goes stale.
self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.add(CONFIG.offlineUrl)))
})

// One cache per version, so activating a new worker is also what throws the
// previous release's assets away. `clients.claim()` puts the fresh worker in
// charge of pages that are already open, which is what makes the reload the
// member is offered actually land on the new one.
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  )
})

// The page asks for this after the member taps "Reload" on the update bar. It
// is the ONLY thing that promotes a waiting worker: doing it unasked would
// swap the assets under a half-written post.
self.addEventListener("message", (event) => {
  if (event.data && event.data.type === "skip-waiting") self.skipWaiting()
})

function isAsset(url) {
  return CONFIG.cacheAssets && url.origin === self.location.origin && url.pathname.startsWith("/assets/")
}

self.addEventListener("fetch", (event) => {
  const request = event.request
  if (request.method !== "GET") return

  const url = new URL(request.url)

  // Digested filenames, so what is in the cache is what the URL asks for and
  // it can be answered without a round trip. A miss falls through to the
  // network and is stored for next time; a network failure is simply a failure
  // (there is no older copy that is any more correct).
  if (isAsset(url)) {
    event.respondWith(
      caches.match(request).then(
        (hit) =>
          hit ||
          fetch(request).then((response) => {
            if (response.ok) {
              const copy = response.clone()
              caches.open(CACHE).then((cache) => cache.put(request, copy))
            }
            return response
          })
      )
    )
    return
  }

  // A page. Straight to the network — never from the cache, never into it —
  // with the offline page standing in when there is no network at all. Only
  // navigations get the fallback: an API call or a LiveView longpoll that
  // answered with an HTML page instead of its own answer would be worse than
  // the error it replaces.
  if (request.mode === "navigate") {
    event.respondWith(fetch(request).catch(() => caches.match(CONFIG.offlineUrl)))
  }

  // Everything else: no respondWith at all, so the browser does exactly what
  // it would do without a worker in the way.
})

// What answers the actual request in the report: a notification while the app
// is closed.
//
// The payload names the notification's kind, its id and where it leads, and
// carries no text (see `Vutuv.WebPush`), so the line drawn here is a generic
// one per kind, in the member's own language — the server puts the strings for
// every locale it serves into CONFIG. What a push turns into is text on a lock
// screen, and the bell is one tap away.
// The server hands over the whole table (`VutuvWeb.PushLine`), so the kinds it
// has a line for are its keys - hardcoding a subset here is a fourth line the
// server could add and this file would silently draw as the generic one.
function line(kind, locale) {
  const strings = CONFIG.strings[kind] || CONFIG.strings.activity || {}
  return strings[locale] || strings[CONFIG.fallbackLocale] || "vutuv"
}

self.addEventListener("push", (event) => {
  let payload = {}
  try {
    payload = event.data ? event.data.json() : {}
  } catch (_e) {
    // A push service may wake a worker with no body at all; the generic line
    // is still better than silence, because something really did happen.
  }

  // Anything the table has no line for is "activity" - which is most kinds, on
  // purpose: a lock screen may say that something happened and must not say
  // what.
  const kind = CONFIG.strings[payload.kind] ? payload.kind : "activity"

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      // Somebody is looking at vutuv right now, so the page's own popup (the
      // WebNotify hook) has this covered and the bell already moved. Anything
      // less than visible — a background tab, a closed app — is exactly what
      // this worker is for. Where both do fire, the shared tag collapses them
      // into one popup rather than stacking two.
      if (clients.some((client) => client.visibilityState === "visible")) return

      return self.registration.showNotification(line(kind, payload.locale), {
        tag: kind === "message" ? "vutuv-messages" : "vutuv-activity",
        icon: CONFIG.icon,
        data: { url: payload.url || "/notifications" },
      })
    })
  )
})

// Because the worker belongs to our origin and the manifest claims `scope:
// "/"`, the tap lands in the installed app rather than in the browser.
// `matchAll` is also what stops it opening a second window on top of an app
// that is already running.
self.addEventListener("notificationclick", (event) => {
  event.notification.close()
  const url = (event.notification.data && event.notification.data.url) || "/notifications"

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      const open = clients.find((client) => client.url.startsWith(self.registration.scope))
      if (!open) return self.clients.openWindow(url)

      // `navigate()` rejects on a window this worker does not control (one
      // opened before it was installed), and a member who tapped a
      // notification has to land somewhere either way.
      return open
        .focus()
        .then((client) => client.navigate(url))
        .catch(() => self.clients.openWindow(url))
    })
  )
})
