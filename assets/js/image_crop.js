// Avatar / cover crop modal — a small, self-contained progressive enhancement
// for the two file inputs on the profile editor (/:slug/edit).
//
// The server keeps the original upload and does the real crop + resize with
// libvips (see Vutuv.Uploads / Vutuv.Uploads.Crop). The browser's only job is
// to let the member pick *which part* of their photo to keep and hand the
// server a crop rectangle as four fractions "x,y,w,h" of the EXIF-rotated
// image, written into a hidden field next to the file input.
//
// Both sides work in the rotated coordinate space: we decode with
// `createImageBitmap(file, {imageOrientation: "from-image"})`, which bakes in
// the EXIF orientation, and the server crops after its own autorotate, so the
// fractions line up no matter how the source was rotated.
//
// Wiring (set in lib/vutuv_web/templates/user/edit.html.heex):
//   <input type="file" data-crop-target="user_avatar_crop" data-crop-aspect="1">
//   <input type="hidden" id="user_avatar_crop" name="user[avatar_crop]">
//   <img data-crop-preview="user_avatar_crop" hidden>
//
// If anything here is unsupported (old browser, decode failure, user cancels)
// the plain file input still submits and the server falls back to its centered
// crop — exactly the behaviour from before this file existed.

const MAX_ZOOM = 4 // up to 4x past "cover" fit

// Delegated so it works regardless of when the inputs appear in the DOM.
function register() {
  document.addEventListener("change", (event) => {
    const input = event.target
    if (input instanceof HTMLInputElement && input.matches('input[type="file"][data-crop-target]')) {
      onFilePicked(input)
    }
  })
}

function onFilePicked(input) {
  const file = input.files && input.files[0]
  const hidden = document.getElementById(input.dataset.cropTarget)

  // A fresh pick clears any crop from a previous selection up front; the modal
  // sets it again on Save. A new upload must never inherit the old crop.
  if (hidden) hidden.value = ""
  clearPreview(input)

  if (!file || !file.type.startsWith("image/") || typeof createImageBitmap !== "function") {
    return // leave the plain upload in place
  }

  createImageBitmap(file, { imageOrientation: "from-image" })
    .then((bitmap) => openCropper(input, hidden, bitmap))
    .catch(() => {}) // decode failed: leave the plain upload in place
}

function openCropper(input, hidden, bitmap) {
  const aspect = parseFloat(input.dataset.cropAspect) || 1
  // Translatable copy comes from the template via data-* (gettext), with
  // English fallbacks here — the same pattern as webauthn.js.
  const labels = {
    title: input.dataset.cropTitle || "Position your photo",
    hint:
      input.dataset.cropHint ||
      "Drag to move, use the slider to zoom. The framed area is what others see.",
    save: input.dataset.cropSave || "Use photo",
    cancel: input.dataset.cropCancel || "Cancel",
    zoom: input.dataset.cropZoom || "Zoom",
  }

  // ── State (all geometry in CSS pixels of the stage) ──
  // scale: image px -> stage px. offset: top-left of the drawn image in the
  // stage. coverScale fills the frame (object-cover); we never zoom out past
  // it, so the frame is always fully covered and every crop fraction is in 0..1.
  let stageW = 0
  let stageH = 0
  let coverScale = 1
  let scale = 1
  let offsetX = 0
  let offsetY = 0

  const ui = buildModal(aspect, labels)
  document.body.appendChild(ui.overlay)

  const ctx = ui.canvas.getContext("2d")
  const dpr = window.devicePixelRatio || 1

  layout()
  window.addEventListener("resize", layout)

  // Size the stage to fit both the dialog width and a viewport-height budget,
  // then recompute the cover fit and redraw. The height budget keeps a tall
  // (square) frame from pushing the Save button off a short screen — the
  // dialog also scrolls as a last resort.
  function layout() {
    const maxH = Math.max(160, window.innerHeight * 0.55)
    const parent = ui.stage.parentElement
    const cs = getComputedStyle(parent)
    stageW = parent.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)
    stageH = Math.round(stageW / aspect)
    if (stageH > maxH) {
      stageH = Math.round(maxH)
      stageW = Math.round(stageH * aspect)
    }
    ui.stage.style.width = `${stageW}px`
    ui.stage.style.height = `${stageH}px`
    ui.canvas.width = Math.round(stageW * dpr)
    ui.canvas.height = Math.round(stageH * dpr)
    ui.canvas.style.width = `${stageW}px`
    ui.canvas.style.height = `${stageH}px`

    coverScale = Math.max(stageW / bitmap.width, stageH / bitmap.height)
    const zoom = parseFloat(ui.zoom.value) || 1
    scale = coverScale * zoom
    // Keep the current focal point roughly centered after a resize.
    offsetX = (stageW - bitmap.width * scale) / 2
    offsetY = (stageH - bitmap.height * scale) / 2
    clampOffsets()
    draw()
  }

  function draw() {
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.clearRect(0, 0, stageW, stageH)
    ctx.drawImage(bitmap, offsetX, offsetY, bitmap.width * scale, bitmap.height * scale)
  }

  // The image must always cover the frame: offsets are bounded so no gap shows.
  function clampOffsets() {
    const drawnW = bitmap.width * scale
    const drawnH = bitmap.height * scale
    offsetX = Math.min(0, Math.max(stageW - drawnW, offsetX))
    offsetY = Math.min(0, Math.max(stageH - drawnH, offsetY))
  }

  // ── Zoom: keep the frame's center fixed while scaling ──
  function applyZoom(nextZoom) {
    nextZoom = Math.min(MAX_ZOOM, Math.max(1, nextZoom))
    ui.zoom.value = String(nextZoom)
    const newScale = coverScale * nextZoom
    const cx = stageW / 2
    const cy = stageH / 2
    // Image point currently under the center stays under the center.
    offsetX = cx - ((cx - offsetX) / scale) * newScale
    offsetY = cy - ((cy - offsetY) / scale) * newScale
    scale = newScale
    clampOffsets()
    draw()
  }

  ui.zoom.addEventListener("input", () => applyZoom(parseFloat(ui.zoom.value) || 1))

  ui.stage.addEventListener(
    "wheel",
    (e) => {
      e.preventDefault()
      const step = e.deltaY < 0 ? 1.08 : 1 / 1.08
      applyZoom((parseFloat(ui.zoom.value) || 1) * step)
    },
    { passive: false }
  )

  // ── Pan: pointer drag works for mouse and touch alike ──
  let dragging = false
  let lastX = 0
  let lastY = 0

  ui.stage.addEventListener("pointerdown", (e) => {
    dragging = true
    lastX = e.clientX
    lastY = e.clientY
    ui.stage.setPointerCapture(e.pointerId)
  })

  ui.stage.addEventListener("pointermove", (e) => {
    if (!dragging) return
    offsetX += e.clientX - lastX
    offsetY += e.clientY - lastY
    lastX = e.clientX
    lastY = e.clientY
    clampOffsets()
    draw()
  })

  const endDrag = () => {
    dragging = false
  }
  ui.stage.addEventListener("pointerup", endDrag)
  ui.stage.addEventListener("pointercancel", endDrag)

  // ── Finish ──
  function cleanup() {
    window.removeEventListener("resize", layout)
    ui.overlay.remove()
    bitmap.close && bitmap.close()
  }

  function cancel() {
    // Drop the selection entirely so nothing uploads on cancel.
    input.value = ""
    if (hidden) hidden.value = ""
    clearPreview(input)
    cleanup()
  }

  function save() {
    // The visible frame maps to this image-space rectangle; express it as
    // fractions for Vutuv.Uploads.Crop.
    const x = clamp01(-offsetX / scale / bitmap.width)
    const y = clamp01(-offsetY / scale / bitmap.height)
    const w = clamp01(stageW / scale / bitmap.width)
    const h = clamp01(stageH / scale / bitmap.height)
    if (hidden) hidden.value = `${round4(x)},${round4(y)},${round4(w)},${round4(h)}`
    showPreview(input, ui, x, y, w, h, bitmap)
    cleanup()
  }

  ui.save.addEventListener("click", save)
  ui.cancel.addEventListener("click", cancel)
  ui.overlay.addEventListener("click", (e) => {
    if (e.target === ui.overlay) cancel()
  })
  document.addEventListener("keydown", function onKey(e) {
    if (!document.body.contains(ui.overlay)) {
      document.removeEventListener("keydown", onKey)
    } else if (e.key === "Escape") {
      cancel()
    }
  })
}

// Builds the modal DOM. Tailwind scans assets/js, so these utility classes are
// part of the build (see app.css `@source "../js"`).
function buildModal(aspect, labels) {
  const overlay = el("div", "fixed inset-0 z-[60] flex items-center justify-center bg-black/70 p-4")
  const dialog = el(
    "div",
    "max-h-[calc(100vh-2rem)] w-full max-w-md overflow-y-auto rounded-2xl bg-white p-4 shadow-xl dark:bg-slate-900"
  )
  const title = el("h2", "text-base font-semibold text-slate-900 dark:text-white", labels.title)
  const hint = el("p", "mt-1 text-xs text-slate-600 dark:text-slate-400", labels.hint)

  // The stage size is set in pixels by layout() (it fits a viewport-height
  // budget, so it is not always full width); mx-auto keeps it centered.
  const stage = el(
    "div",
    "relative mx-auto mt-3 touch-none select-none overflow-hidden rounded-lg bg-slate-100 ring-1 ring-slate-200 dark:bg-slate-800 dark:ring-slate-700"
  )
  const canvas = el("canvas", "block h-full w-full cursor-grab active:cursor-grabbing")
  // A frame outline so the cropped area reads clearly (the whole stage IS the
  // crop, so this is just a visual cue, not a separate region).
  const frame = el("div", "pointer-events-none absolute inset-0 rounded-lg ring-2 ring-white/70")
  stage.append(canvas, frame)

  const zoom = el("input", "mt-3 block w-full accent-brand-600")
  zoom.type = "range"
  zoom.min = "1"
  zoom.max = String(MAX_ZOOM)
  zoom.step = "0.01"
  zoom.value = "1"
  zoom.setAttribute("aria-label", labels.zoom)

  const actions = el("div", "mt-4 flex items-center justify-end gap-3")
  const cancel = el(
    "button",
    "rounded-lg bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700",
    labels.cancel
  )
  cancel.type = "button"
  const save = el(
    "button",
    "rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700",
    labels.save
  )
  save.type = "button"
  actions.append(cancel, save)

  dialog.append(title, hint, stage, zoom, actions)
  overlay.appendChild(dialog)
  return { overlay, dialog, stage, canvas, zoom, save, cancel }
}

// After Save, show the chosen crop as a small preview next to the input so the
// member sees what they picked without reopening the modal.
function showPreview(input, ui, x, y, w, h, bitmap) {
  const img = document.querySelector(`[data-crop-preview="${input.dataset.cropTarget}"]`)
  if (!img) return
  const sx = x * bitmap.width
  const sy = y * bitmap.height
  const sw = w * bitmap.width
  const sh = h * bitmap.height
  const out = document.createElement("canvas")
  const maxW = 240
  out.width = Math.min(maxW, Math.round(sw))
  out.height = Math.round(out.width * (sh / sw))
  out.getContext("2d").drawImage(bitmap, sx, sy, sw, sh, 0, 0, out.width, out.height)
  img.src = out.toDataURL("image/png")
  img.hidden = false
}

function clearPreview(input) {
  const img = document.querySelector(`[data-crop-preview="${input.dataset.cropTarget}"]`)
  if (img) {
    img.hidden = true
    img.removeAttribute("src")
  }
}

function el(tag, className, text) {
  const node = document.createElement(tag)
  if (className) node.className = className
  if (text != null) node.textContent = text
  return node
}

const clamp01 = (v) => Math.min(1, Math.max(0, v))
const round4 = (v) => Math.round(v * 10000) / 10000

register()
