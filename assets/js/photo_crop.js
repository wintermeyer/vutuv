// Ratio crop dialog for post photos — the composer's sibling of the avatar
// crop modal (image_crop.js), with two differences that matter:
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
  // ── State (geometry in CSS pixels of the stage) ──
  // aspect: the frame's shape (a RATIOS value). scale: image px -> stage px;
  // coverScale is the object-cover fit, the zoom floor, so the frame is
  // always fully covered and every fraction stays in 0..1.
  let aspect = initialAspect(bitmap, stored)
  let stageW = 0
  let stageH = 0
  let coverScale = 1
  let scale = 1
  let offsetX = 0
  let offsetY = 0

  const ui = buildDialog(labels, stored != null, aspect)
  document.body.appendChild(ui.overlay)

  const ctx = ui.canvas.getContext("2d")
  const dpr = window.devicePixelRatio || 1

  layout()
  if (stored) applyStored(stored)
  window.addEventListener("resize", layout)

  // Size the stage to the dialog width within a viewport-height budget (a
  // 9:16 frame would otherwise push the buttons off a phone screen), then
  // recompute the cover fit and start centered at the current zoom.
  function layout() {
    const maxH = Math.max(160, window.innerHeight * 0.5)
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
    scale = coverScale * (parseFloat(ui.zoom.value) || 1)
    offsetX = (stageW - bitmap.width * scale) / 2
    offsetY = (stageH - bitmap.height * scale) / 2
    clampOffsets()
    draw()
  }

  // Re-establish a stored crop: zoom so the stored width fills the frame,
  // then place its corner. Approximate on purpose — the stored shape came
  // from this same chip row, so the frame ratio matches within rounding and
  // the clamps absorb the rest.
  function applyStored({ x, y, w }) {
    const targetScale = clamp(stageW / (w * bitmap.width), coverScale, coverScale * MAX_ZOOM)
    ui.zoom.value = String(targetScale / coverScale)
    scale = targetScale
    offsetX = -x * bitmap.width * scale
    offsetY = -y * bitmap.height * scale
    clampOffsets()
    draw()
  }

  function draw() {
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.clearRect(0, 0, stageW, stageH)
    ctx.drawImage(bitmap, offsetX, offsetY, bitmap.width * scale, bitmap.height * scale)
  }

  function clampOffsets() {
    offsetX = Math.min(0, Math.max(stageW - bitmap.width * scale, offsetX))
    offsetY = Math.min(0, Math.max(stageH - bitmap.height * scale, offsetY))
  }

  // ── Zoom: keep a focal point fixed while scaling ──
  function zoomAt(cx, cy, nextScale) {
    nextScale = clamp(nextScale, coverScale, coverScale * MAX_ZOOM)
    offsetX = cx - ((cx - offsetX) / scale) * nextScale
    offsetY = cy - ((cy - offsetY) / scale) * nextScale
    scale = nextScale
    ui.zoom.value = String(scale / coverScale)
    clampOffsets()
    draw()
  }

  ui.zoom.addEventListener("input", () => {
    zoomAt(stageW / 2, stageH / 2, coverScale * (parseFloat(ui.zoom.value) || 1))
  })

  ui.stage.addEventListener(
    "wheel",
    (e) => {
      e.preventDefault()
      const step = e.deltaY < 0 ? 1.08 : 1 / 1.08
      zoomAt(stageW / 2, stageH / 2, scale * step)
    },
    { passive: false }
  )

  // ── Ratio chips: reshape the frame, restart centered at cover fit ──
  ui.chips.forEach((chip) => {
    chip.addEventListener("click", () => {
      aspect = parseFloat(chip.dataset.ratio)
      ui.chips.forEach((c) => c.setAttribute("aria-pressed", String(c === chip)))
      ui.chips.forEach((c) => c.classList.toggle("bg-brand-600", c === chip))
      ui.chips.forEach((c) => c.classList.toggle("text-white", c === chip))
      ui.zoom.value = "1"
      layout()
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
        zoomAt(mid.x - stageBox.left, mid.y - stageBox.top, scale * (distance / pinchDistance))
      }
      pinchDistance = distance
    } else if (pointers.size === 1) {
      offsetX += e.clientX - prev.x
      offsetY += e.clientY - prev.y
      clampOffsets()
      draw()
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

  // ── Finish ──
  function cleanup() {
    window.removeEventListener("resize", layout)
    ui.overlay.remove()
    bitmap.close && bitmap.close()
  }

  function apply() {
    const x = clamp01(-offsetX / scale / bitmap.width)
    const y = clamp01(-offsetY / scale / bitmap.height)
    const w = clamp01(stageW / scale / bitmap.width)
    const h = clamp01(stageH / scale / bitmap.height)
    onSave(`${round4(x)},${round4(y)},${round4(w)},${round4(h)}`)
    cleanup()
  }

  ui.save.addEventListener("click", apply)
  ui.cancel.addEventListener("click", cleanup)
  if (ui.reset) {
    ui.reset.addEventListener("click", () => {
      onSave("")
      cleanup()
    })
  }
  ui.overlay.addEventListener("click", (e) => {
    if (e.target === ui.overlay) cleanup()
  })
  document.addEventListener("keydown", function onKey(e) {
    if (!document.body.contains(ui.overlay)) {
      document.removeEventListener("keydown", onKey)
    } else if (e.key === "Escape") {
      cleanup()
    }
  })
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

  const stage = el(
    "div",
    "relative mx-auto mt-3 touch-none select-none overflow-hidden rounded-lg bg-slate-100 ring-1 ring-slate-200 dark:bg-slate-800 dark:ring-slate-700"
  )
  const canvas = el("canvas", "block h-full w-full cursor-grab active:cursor-grabbing")
  const frame = el("div", "pointer-events-none absolute inset-0 rounded-lg ring-2 ring-white/70")
  stage.append(canvas, frame)

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

function el(tag, className, text) {
  const node = document.createElement(tag)
  if (className) node.className = className
  if (text != null) node.textContent = text
  return node
}

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v))
const clamp01 = (v) => Math.min(1, Math.max(0, v))
const round4 = (v) => Math.round(v * 10000) / 10000
