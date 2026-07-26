// The photo lightbox on the post permalink (issue #1104).
//
// It is deliberately built as a page-level enhancement rather than a LiveView
// component. The permalink's conversation IS a LiveView, and an overlay living
// inside it would be re-rendered by morphdom on every unrelated counter tick —
// closing itself while somebody is looking at a photo. So the overlay is one
// element appended to <body>, outside every LiveView root, and the gallery
// links only carry the data it reads.
//
// Everything it shows comes off the clicked link's data-photo-* attributes, so
// there is one copy of the caption, the camera line, the download and the
// licence: the ones the page already rendered. With JavaScript off the same
// links are plain hrefs to the full-size image, which is what they were before
// the lightbox existed.

import { onReady } from "./util"

let overlay = null
let photos = []
let current = 0
let lastFocus = null
let labels = {}

// The overlay's own wording, rendered by the server onto the gallery so it is
// translated like everything else on the page.
function applyLabels(gallery) {
  labels = {
    close: gallery.dataset.labelClose || "",
    prev: gallery.dataset.labelPrev || "",
    next: gallery.dataset.labelNext || "",
    download: gallery.dataset.labelDownload || "",
  }

  overlay.querySelector("[data-lb-close]").setAttribute("aria-label", labels.close)
  overlay.querySelector("[data-lb-prev]").setAttribute("aria-label", labels.prev)
  overlay.querySelector("[data-lb-next]").setAttribute("aria-label", labels.next)
}

// One overlay for the whole page, built lazily on the first open. The markup
// is a fixed template with no interpolation: every value the page supplies is
// written through textContent or a URL property below, never spliced into
// HTML. Its own chrome labels come from the gallery's data attributes, because
// the server is the only place that knows the reader's language.
function build() {
  if (overlay) return overlay

  overlay = document.createElement("div")
  overlay.className = "lightbox"
  overlay.setAttribute("role", "dialog")
  overlay.setAttribute("aria-modal", "true")
  overlay.hidden = true
  overlay.innerHTML = `
    <button type="button" class="lightbox__close" data-lb-close>&times;</button>
    <button type="button" class="lightbox__nav lightbox__nav--prev" data-lb-prev>&#8249;</button>
    <button type="button" class="lightbox__nav lightbox__nav--next" data-lb-next>&#8250;</button>
    <figure class="lightbox__stage">
      <img class="lightbox__image" data-lb-image alt="" />
      <figcaption class="lightbox__meta">
        <p class="lightbox__caption" data-lb-caption></p>
        <p class="lightbox__camera" data-lb-camera></p>
        <p class="lightbox__footer">
          <span class="lightbox__position" data-lb-position></span>
          <a class="lightbox__license" data-lb-license target="_blank" rel="license noopener"></a>
          <a class="lightbox__download" data-lb-download download></a>
        </p>
      </figcaption>
    </figure>
  `
  document.body.appendChild(overlay)

  overlay.addEventListener("click", (e) => {
    if (e.target.closest("[data-lb-close]")) return close()
    if (e.target.closest("[data-lb-prev]")) return step(-1)
    if (e.target.closest("[data-lb-next]")) return step(1)
    // A click on the backdrop (not on the picture or its caption block) closes,
    // which is what every viewer expects of a full-screen overlay.
    if (!e.target.closest(".lightbox__stage")) close()
  })

  // Swipe, so a phone gets the same navigation the arrow keys give a desktop.
  let startX = null
  overlay.addEventListener("touchstart", (e) => (startX = e.touches[0].clientX), { passive: true })
  overlay.addEventListener(
    "touchend",
    (e) => {
      if (startX === null) return
      const dx = e.changedTouches[0].clientX - startX
      if (Math.abs(dx) > 50) step(dx < 0 ? 1 : -1)
      startX = null
    },
    { passive: true }
  )

  return overlay
}

function show(index) {
  const photo = photos[index]
  if (!photo) return
  current = index

  const q = (sel) => overlay.querySelector(sel)
  const image = q("[data-lb-image]")
  image.src = photo.dataset.photoSrc || photo.href
  image.alt = photo.dataset.photoAlt || ""

  text(q("[data-lb-caption]"), photo.dataset.photoCaption)
  text(q("[data-lb-camera]"), photo.dataset.photoCamera)
  text(q("[data-lb-position]"), photos.length > 1 ? photo.dataset.photoPosition : "")

  const license = q("[data-lb-license]")
  text(license, photo.dataset.photoLicense)
  license.href = photo.dataset.photoLicenseUrl || "#"
  // A licence with no deed to link (all rights reserved) stays a plain label
  // rather than a link to nowhere.
  license.classList.toggle("is-plain", !photo.dataset.photoLicenseUrl)

  const download = q("[data-lb-download]")
  const href = photo.dataset.photoDownload
  text(download, href ? labels.download : "")
  if (href) download.href = href

  // Only ever navigate within one gallery.
  const many = photos.length > 1
  q("[data-lb-prev]").hidden = !many
  q("[data-lb-next]").hidden = !many

  // Warm the neighbours so stepping through a set does not flash.
  ;[index - 1, index + 1].forEach((i) => {
    const neighbour = photos[i]
    if (neighbour) new Image().src = neighbour.dataset.photoSrc || neighbour.href
  })
}

// An empty value hides the line entirely — a stray blank row under a photo
// reads as a rendering fault.
function text(el, value) {
  el.textContent = value || ""
  el.hidden = !value
}

function open(gallery, index) {
  build()
  applyLabels(gallery)
  photos = [...gallery.querySelectorAll("[data-lightbox-photo]")]
  lastFocus = document.activeElement
  overlay.hidden = false
  // The page behind must not scroll while the overlay owns the screen.
  document.documentElement.classList.add("lightbox-open")
  show(index)
  overlay.querySelector("[data-lb-close]").focus()
}

function close() {
  if (!overlay || overlay.hidden) return
  overlay.hidden = true
  document.documentElement.classList.remove("lightbox-open")
  // Give focus back where it came from, so keyboard users are not dropped at
  // the top of the document.
  lastFocus?.focus()
  lastFocus = null
}

function step(delta) {
  if (photos.length < 2) return
  show((current + delta + photos.length) % photos.length)
}

onReady(() => {
  document.addEventListener("click", (e) => {
    const link = e.target.closest("[data-lightbox-photo]")
    if (!link) return
    // Let a modified click do what the browser would: open the full image in a
    // new tab. The href is a real URL precisely so that still works.
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return
    const gallery = link.closest("[data-lightbox-gallery]")
    if (!gallery) return
    e.preventDefault()
    open(gallery, Number(link.dataset.lightboxPhoto) || 0)
  })

  document.addEventListener("keydown", (e) => {
    if (!overlay || overlay.hidden) return
    if (e.key === "Escape") close()
    else if (e.key === "ArrowLeft") step(-1)
    else if (e.key === "ArrowRight") step(1)
    else return
    e.preventDefault()
  })
})
