// Avatar / cover crop modal — a small, self-contained progressive enhancement
// for the two file inputs on the profile editor (/:slug/edit). The stage
// geometry it shares with the post-photo dialog lives in crop_stage.js.
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

import { bindEscape, buildStage, createCropStage, cropString, el } from "./crop_stage"

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

  const ui = buildModal(aspect, labels)
  document.body.appendChild(ui.overlay)

  // st owns the stage geometry — layout, cover-fit zoom floor, offsets and
  // the crop-fraction math (see crop_stage.js).
  const st = createCropStage({
    overlay: ui.overlay,
    stage: ui.stage,
    canvas: ui.canvas,
    zoom: ui.zoom,
    bitmap,
    aspect,
    // The height budget keeps a tall (square) frame from pushing the Save
    // button off a short screen — the dialog also scrolls as a last resort.
    maxHFactor: 0.55,
  })

  // ── Zoom: keep the frame's center fixed while scaling ──
  function applyZoom(nextZoom) {
    nextZoom = Math.min(MAX_ZOOM, Math.max(1, nextZoom))
    ui.zoom.value = String(nextZoom)
    const newScale = st.coverScale * nextZoom
    const cx = st.stageW / 2
    const cy = st.stageH / 2
    // Image point currently under the center stays under the center.
    st.offsetX = cx - ((cx - st.offsetX) / st.scale) * newScale
    st.offsetY = cy - ((cy - st.offsetY) / st.scale) * newScale
    st.scale = newScale
    st.clampOffsets()
    st.draw()
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
    st.offsetX += e.clientX - lastX
    st.offsetY += e.clientY - lastY
    lastX = e.clientX
    lastY = e.clientY
    st.clampOffsets()
    st.draw()
  })

  const endDrag = () => {
    dragging = false
  }
  ui.stage.addEventListener("pointerup", endDrag)
  ui.stage.addEventListener("pointercancel", endDrag)

  // ── Finish ── (st.destroy is the whole teardown: resize unbind, overlay,
  // bitmap — see crop_stage.js)
  function cancel() {
    // Drop the selection entirely so nothing uploads on cancel.
    input.value = ""
    if (hidden) hidden.value = ""
    clearPreview(input)
    st.destroy()
  }

  function save() {
    // The visible frame maps to this image-space rectangle; hand the server
    // the fractions Vutuv.Uploads.Crop expects.
    const { x, y, w, h } = st.fractions()
    if (hidden) hidden.value = cropString({ x, y, w, h })
    showPreview(input, ui, x, y, w, h, bitmap)
    st.destroy()
  }

  ui.save.addEventListener("click", save)
  ui.cancel.addEventListener("click", cancel)
  ui.overlay.addEventListener("click", (e) => {
    if (e.target === ui.overlay) cancel()
  })
  bindEscape(ui.overlay, cancel)
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

  const { stage, canvas } = buildStage()

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

register()
