// Ratio crop dialog for post photos — the composer's sibling of the avatar
// crop modal (image_crop.js; the stage geometry both dialogs share lives in
// crop_stage.js), with two differences that matter:
//
//   * It crops a photo that is ALREADY uploaded (post images upload eagerly),
//     so the picture comes from the author-only `source` workbench URL — the
//     uncropped frame at feed size, which the server keeps serving to the
//     author alone however often the photo is re-cropped. The crop fractions
//     are relative dimensions, so fractions of the workbench rendering are
//     fractions of the full-resolution original.
//
//   * The frame is not fixed: a chip row offers the popular shapes (1:1,
//     4:3, 16:9 and friends — deliberately no freeform handle; a shape from
//     this row is the whole point). Picking a chip reshapes the frame, then
//     drag / pinch / wheel / slider position the photo under it, exactly the
//     interaction the avatar modal trains.
//
// The dialog itself never writes anything: "Apply" hands the fractions (or
// "" for "whole photo") to the caller, and the composer's LiveComponent does
// the real work server-side (Vutuv.Posts.crop_image/2). Cancel and Escape
// change nothing. Labels arrive translated via data-* attributes, like the
// lightbox's.

import { bindEscape, buildStage, createCropStage, cropString, el } from "./crop_stage"

const MAX_ZOOM = 4

// The popular shapes, landscape and portrait alike. "3:2" is the classic
// camera frame, "16:9" the screen, "4:5" the portrait feed standard.
const RATIOS = [
  { label: "1:1", value: 1 },
  { label: "4:3", value: 4 / 3 },
  { label: "3:4", value: 3 / 4 },
  { label: "3:2", value: 3 / 2 },
  { label: "2:3", value: 2 / 3 },
  { label: "16:9", value: 16 / 9 },
  { label: "9:16", value: 9 / 16 },
]

// Opens the dialog for a tile's crop button. `labels` carries the translated
// copy (read off the grid's data-crop-* attributes by the caller); `onSave`
// receives the crop string ("x,y,w,h" fractions, or "" to reset).
export function openPhotoCropper(button, labels, onSave) {
  const src = button.dataset.cropSrc
  if (!src || typeof createImageBitmap !== "function" || document.querySelector("[data-photo-crop-overlay]")) return

  fetch(src, { credentials: "same-origin" })
    .then((res) => (res.ok ? res.blob() : Promise.reject(new Error("unavailable"))))
    .then((blob) => createImageBitmap(blob))
    .then((bitmap) => openDialog(bitmap, parseCrop(button.dataset.cropValue), labels, onSave))
    .catch(() => {})
}

function openDialog(bitmap, stored, labels, onSave) {
  const aspect = initialAspect(bitmap, stored)
  const ui = buildDialog(labels, stored != null, aspect)
  document.body.appendChild(ui.overlay)

  // st owns the stage geometry — layout, cover-fit zoom floor, offsets and
  // the crop-fraction math (see crop_stage.js). The frame's shape starts at
  // the preselected chip's ratio and follows the chip row via st.aspect.
  const st = createCropStage({
    overlay: ui.overlay,
    stage: ui.stage,
    canvas: ui.canvas,
    zoom: ui.zoom,
    bitmap,
    aspect,
    // Tighter height budget than the avatar modal's 0.55: the chip row needs
    // the room, and a 9:16 frame would push the buttons off a phone screen.
    maxHFactor: 0.5,
  })
  if (stored) applyStored(stored)

  // Re-establish a stored crop: zoom so the stored width fills the frame,
  // then place its corner. Approximate on purpose — the stored shape came
  // from this same chip row, so the frame ratio matches within rounding and
  // the clamps absorb the rest.
  function applyStored({ x, y, w }) {
    const targetScale = clamp(st.stageW / (w * bitmap.width), st.coverScale, st.coverScale * MAX_ZOOM)
    ui.zoom.value = String(targetScale / st.coverScale)
    st.scale = targetScale
    st.offsetX = -x * bitmap.width * st.scale
    st.offsetY = -y * bitmap.height * st.scale
    st.clampOffsets()
    st.draw()
  }

  // ── Zoom: keep a focal point fixed while scaling ──
  function zoomAt(cx, cy, nextScale) {
    nextScale = clamp(nextScale, st.coverScale, st.coverScale * MAX_ZOOM)
    st.offsetX = cx - ((cx - st.offsetX) / st.scale) * nextScale
    st.offsetY = cy - ((cy - st.offsetY) / st.scale) * nextScale
    st.scale = nextScale
    ui.zoom.value = String(st.scale / st.coverScale)
    st.clampOffsets()
    st.draw()
  }

  ui.zoom.addEventListener("input", () => {
    zoomAt(st.stageW / 2, st.stageH / 2, st.coverScale * (parseFloat(ui.zoom.value) || 1))
  })

  ui.stage.addEventListener(
    "wheel",
    (e) => {
      e.preventDefault()
      const step = e.deltaY < 0 ? 1.08 : 1 / 1.08
      zoomAt(st.stageW / 2, st.stageH / 2, st.scale * step)
    },
    { passive: false }
  )

  // ── Ratio chips: reshape the frame, restart centered at cover fit ──
  ui.chips.forEach((chip) => {
    chip.addEventListener("click", () => {
      st.aspect = parseFloat(chip.dataset.ratio)
      ui.chips.forEach((c) => c.setAttribute("aria-pressed", String(c === chip)))
      ui.chips.forEach((c) => c.classList.toggle("bg-brand-600", c === chip))
      ui.chips.forEach((c) => c.classList.toggle("text-white", c === chip))
      ui.zoom.value = "1"
      st.layout()
    })
  })

  // ── Pan + pinch: pointer events cover mouse and touch alike ──
  const pointers = new Map()
  let pinchDistance = 0

  ui.stage.addEventListener("pointerdown", (e) => {
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY })
    ui.stage.setPointerCapture(e.pointerId)
    if (pointers.size === 2) pinchDistance = pointerDistance()
  })

  ui.stage.addEventListener("pointermove", (e) => {
    const prev = pointers.get(e.pointerId)
    if (!prev) return
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY })

    if (pointers.size === 2) {
      const distance = pointerDistance()
      if (pinchDistance > 0 && distance > 0) {
        const stageBox = ui.stage.getBoundingClientRect()
        const mid = pointerMidpoint()
        zoomAt(mid.x - stageBox.left, mid.y - stageBox.top, st.scale * (distance / pinchDistance))
      }
      pinchDistance = distance
    } else if (pointers.size === 1) {
      st.offsetX += e.clientX - prev.x
      st.offsetY += e.clientY - prev.y
      st.clampOffsets()
      st.draw()
    }
  })

  const releasePointer = (e) => {
    pointers.delete(e.pointerId)
    pinchDistance = pointers.size === 2 ? pointerDistance() : 0
  }
  ui.stage.addEventListener("pointerup", releasePointer)
  ui.stage.addEventListener("pointercancel", releasePointer)

  function pointerDistance() {
    const [a, b] = [...pointers.values()]
    return Math.hypot(a.x - b.x, a.y - b.y)
  }

  function pointerMidpoint() {
    const [a, b] = [...pointers.values()]
    return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }
  }

  // ── Finish ── (st.destroy is the whole teardown: resize unbind, overlay,
  // bitmap — see crop_stage.js)
  function apply() {
    onSave(cropString(st.fractions()))
    st.destroy()
  }

  ui.save.addEventListener("click", apply)
  ui.cancel.addEventListener("click", st.destroy)
  if (ui.reset) {
    ui.reset.addEventListener("click", () => {
      onSave("")
      st.destroy()
    })
  }
  ui.overlay.addEventListener("click", (e) => {
    if (e.target === ui.overlay) st.destroy()
  })
  bindEscape(ui.overlay, st.destroy)
}

// The chip preselected when the dialog opens: the stored crop's shape, else
// the shape nearest the photo's own — the least destructive starting point.
function initialAspect(bitmap, stored) {
  const target = stored ? stored.w / stored.h * (bitmap.width / bitmap.height) : bitmap.width / bitmap.height
  return nearestRatio(target)
}

function nearestRatio(target) {
  return RATIOS.reduce(
    (best, ratio) =>
      Math.abs(Math.log(ratio.value / target)) < Math.abs(Math.log(best / target))
        ? ratio.value
        : best,
    RATIOS[0].value
  )
}

function parseCrop(value) {
  if (!value) return null
  const parts = value.split(",").map(parseFloat)
  if (parts.length !== 4 || parts.some((n) => !isFinite(n))) return null
  const [x, y, w, h] = parts
  if (w <= 0 || h <= 0) return null
  return { x, y, w, h }
}

// Builds the dialog DOM. Tailwind scans assets/js, so these utility classes
// are part of the build (app.css `@source "../js"`).
function buildDialog(labels, resettable, activeAspect) {
  const overlay = el("div", "fixed inset-0 z-[60] flex items-center justify-center bg-black/70 p-4")
  overlay.setAttribute("data-photo-crop-overlay", "")
  const dialog = el(
    "div",
    "max-h-[calc(100vh-2rem)] w-full max-w-md overflow-y-auto rounded-2xl bg-white p-4 shadow-xl dark:bg-slate-900"
  )
  const title = el("h2", "text-base font-semibold text-slate-900 dark:text-white", labels.title)
  const hint = el("p", "mt-1 text-xs text-slate-600 dark:text-slate-400", labels.hint)

  const chipRow = el("div", "-mx-1 mt-3 flex gap-1.5 overflow-x-auto px-1 pb-1")
  const chips = RATIOS.map((ratio) => {
    const active = Math.abs(ratio.value - activeAspect) < 0.001
    const chip = el(
      "button",
      "h-9 shrink-0 rounded-lg px-3 text-sm font-semibold ring-1 ring-slate-300 dark:ring-slate-600 " +
        (active ? "bg-brand-600 text-white" : "text-slate-700 hover:bg-slate-100 dark:text-slate-200 dark:hover:bg-slate-800"),
      ratio.label
    )
    chip.type = "button"
    chip.dataset.ratio = String(ratio.value)
    chip.setAttribute("aria-pressed", String(active))
    chipRow.appendChild(chip)
    return chip
  })

  const { stage, canvas } = buildStage()

  const zoom = el("input", "mt-3 block w-full accent-brand-600")
  zoom.type = "range"
  zoom.min = "1"
  zoom.max = String(MAX_ZOOM)
  zoom.step = "0.01"
  zoom.value = "1"
  zoom.setAttribute("aria-label", labels.zoom)

  const actions = el("div", "mt-4 flex flex-wrap items-center justify-end gap-3")
  let reset = null
  if (resettable) {
    reset = el(
      "button",
      "mr-auto rounded-lg px-3 py-2 text-sm font-semibold text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-slate-100",
      labels.reset
    )
    reset.type = "button"
    actions.appendChild(reset)
  }
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

  dialog.append(title, hint, chipRow, stage, zoom, actions)
  overlay.appendChild(dialog)
  return { overlay, dialog, stage, canvas, zoom, chips, save, cancel, reset }
}

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v))
