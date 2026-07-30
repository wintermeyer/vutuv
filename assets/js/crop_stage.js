// The crop stage shared by both crop dialogs — the avatar/cover modal on the
// profile editor (image_crop.js) and the composer's post-photo ratio dialog
// (photo_crop.js). Both train the same interaction: a fixed frame (the
// "stage") over a canvas, with the photo dragged / zoomed underneath until
// the right part sits inside it.
//
// What lives here is what the two croppers had as identical copies: the
// stage DOM chunk, the geometry (layout / draw / clampOffsets and the
// crop-fraction math) and the dialog scaffolding (Escape, teardown).
// Everything that genuinely differs — the rest of the dialog DOM, the zoom
// and pan interactions, where the fractions go on Save — stays local to the
// croppers.

// Tiny DOM builder both dialogs use. Tailwind scans assets/js, so utility
// classes written through it are part of the build (app.css `@source "../js"`).
export function el(tag, className, text) {
  const node = document.createElement(tag)
  if (className) node.className = className
  if (text != null) node.textContent = text
  return node
}

// The stage DOM: a canvas the photo draws into, under a frame outline so the
// cropped area reads clearly (the whole stage IS the crop, so the frame is a
// visual cue, not a separate region). layout() sizes the stage in pixels —
// it fits a viewport-height budget, so it is not always full width; mx-auto
// keeps it centered.
export function buildStage() {
  const stage = el(
    "div",
    "relative mx-auto mt-3 touch-none select-none overflow-hidden rounded-lg bg-slate-100 ring-1 ring-slate-200 dark:bg-slate-800 dark:ring-slate-700"
  )
  const canvas = el("canvas", "block h-full w-full cursor-grab active:cursor-grabbing")
  const frame = el("div", "pointer-events-none absolute inset-0 rounded-lg ring-2 ring-white/70")
  stage.append(canvas, frame)
  return { stage, canvas }
}

// The geometry controller for one open dialog. All geometry is in CSS pixels
// of the stage: `scale` maps image px -> stage px, `coverScale` is the
// object-cover fit and the zoom floor, so the frame is always fully covered
// and every crop fraction stays in 0..1. The zoom slider's value is read as
// the factor past cover fit (1 = cover).
//
// Create it after the overlay is in the DOM (layout() measures the stage's
// parent); it lays out once immediately and re-lays out on window resize.
// destroy() is the whole teardown: it unbinds that listener, removes the
// overlay and closes the bitmap. `maxHFactor` is the stage's viewport-height
// budget — a tall frame would otherwise push the dialog's buttons off a
// phone screen (the dialog also scrolls as a last resort).
export function createCropStage({ overlay, stage, canvas, zoom, bitmap, aspect, maxHFactor }) {
  const ctx = canvas.getContext("2d")
  const dpr = window.devicePixelRatio || 1

  const st = {
    aspect, // the frame's shape (w/h); photo_crop's ratio chips reassign it
    stageW: 0,
    stageH: 0,
    coverScale: 1,
    scale: 1,
    offsetX: 0,
    offsetY: 0,

    // Size the stage to the dialog width within the viewport-height budget,
    // then recompute the cover fit and start centered at the current zoom.
    layout() {
      const maxH = Math.max(160, window.innerHeight * maxHFactor)
      const parent = stage.parentElement
      const cs = getComputedStyle(parent)
      st.stageW = parent.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)
      st.stageH = Math.round(st.stageW / st.aspect)
      if (st.stageH > maxH) {
        st.stageH = Math.round(maxH)
        st.stageW = Math.round(st.stageH * st.aspect)
      }
      stage.style.width = `${st.stageW}px`
      stage.style.height = `${st.stageH}px`
      canvas.width = Math.round(st.stageW * dpr)
      canvas.height = Math.round(st.stageH * dpr)
      canvas.style.width = `${st.stageW}px`
      canvas.style.height = `${st.stageH}px`

      st.coverScale = Math.max(st.stageW / bitmap.width, st.stageH / bitmap.height)
      st.scale = st.coverScale * (parseFloat(zoom.value) || 1)
      st.offsetX = (st.stageW - bitmap.width * st.scale) / 2
      st.offsetY = (st.stageH - bitmap.height * st.scale) / 2
      st.clampOffsets()
      st.draw()
    },

    draw() {
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      ctx.clearRect(0, 0, st.stageW, st.stageH)
      ctx.drawImage(bitmap, st.offsetX, st.offsetY, bitmap.width * st.scale, bitmap.height * st.scale)
    },

    // The image must always cover the frame: offsets are bounded so no gap shows.
    clampOffsets() {
      st.offsetX = Math.min(0, Math.max(st.stageW - bitmap.width * st.scale, st.offsetX))
      st.offsetY = Math.min(0, Math.max(st.stageH - bitmap.height * st.scale, st.offsetY))
    },

    // The visible frame maps to this image-space rectangle, expressed as
    // fractions of the bitmap (serialized "x,y,w,h" via cropString below) —
    // the format the server-side croppers share.
    fractions() {
      return {
        x: clamp01(-st.offsetX / st.scale / bitmap.width),
        y: clamp01(-st.offsetY / st.scale / bitmap.height),
        w: clamp01(st.stageW / st.scale / bitmap.width),
        h: clamp01(st.stageH / st.scale / bitmap.height),
      }
    },

    destroy() {
      window.removeEventListener("resize", st.layout)
      overlay.remove()
      bitmap.close && bitmap.close()
    },
  }

  st.layout()
  window.addEventListener("resize", st.layout)
  return st
}

// Escape closes the dialog like Cancel. The listener unhooks itself on the
// first keydown after the overlay is gone (however it was closed).
export function bindEscape(overlay, onEscape) {
  document.addEventListener("keydown", function onKey(e) {
    if (!document.body.contains(overlay)) {
      document.removeEventListener("keydown", onKey)
    } else if (e.key === "Escape") {
      onEscape()
    }
  })
}

// Serializes crop fractions for the server, four decimals apiece.
export function cropString({ x, y, w, h }) {
  return `${round4(x)},${round4(y)},${round4(w)},${round4(h)}`
}

const clamp01 = (v) => Math.min(1, Math.max(0, v))
const round4 = (v) => Math.round(v * 10000) / 10000
