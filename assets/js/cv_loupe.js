// The profile's CV card (VutuvWeb.UI.cv_card) draws the CV's first page as a
// print document scaled to 88 px, too small to read. Under a mouse this hook
// puts a round loupe that draws the same page at a readable size, so a visitor
// can look before opening the builder.
//
// * The loupe's page is a clone of the thumbnail's frame, made on the first
//   hover, so the server renders the document once.
// * It hangs on <body>, outside the LiveView tree, where a patch cannot drop
//   it, and it takes no pointer events: the click still reaches the link.
// * Only a mouse gets it. A finger or a pen has no hover to end it again, so
//   there the thumbnail is just the link.

const SIZE = 184 // the loupe's diameter in CSS px
const BORDER = 3
const ZOOM = 0.72 // the page's scale inside it; 14px text reads at 10px

const clamp01 = (n) => Math.min(Math.max(n, 0), 1)

export const CVLoupe = {
  mounted() {
    this.onMove = (e) => this.move(e)
    this.onLeave = () => this.hide()
    this.el.addEventListener("pointerenter", this.onMove)
    this.el.addEventListener("pointermove", this.onMove)
    this.el.addEventListener("pointerleave", this.onLeave)
  },

  updated() {
    const source = this.el.querySelector("iframe")
    if (this.page && this.page.srcdoc !== source.srcdoc) this.page.srcdoc = source.srcdoc
  },

  destroyed() {
    window.removeEventListener("scroll", this.onLeave)
    this.loupe?.remove()
  },

  build() {
    const source = this.el.querySelector("iframe")
    // offsetWidth ignores the thumbnail's scale, so this is the page's own size.
    this.sheet = { width: source.offsetWidth, height: source.offsetHeight }

    this.loupe = document.createElement("div")
    this.loupe.setAttribute("aria-hidden", "true")
    Object.assign(this.loupe.style, {
      position: "fixed",
      left: "0",
      top: "0",
      zIndex: "70",
      width: `${SIZE}px`,
      height: `${SIZE}px`,
      borderRadius: "50%",
      overflow: "hidden",
      background: "#fff",
      border: `${BORDER}px solid #fff`,
      boxShadow: "0 0 0 1px rgb(15 23 42 / 0.2), 0 12px 32px rgb(15 23 42 / 0.3)",
      pointerEvents: "none",
      display: "none",
    })

    this.page = source.cloneNode(false)
    Object.assign(this.page.style, { position: "absolute", left: "0", top: "0" })
    this.loupe.appendChild(this.page)
    document.body.appendChild(this.loupe)

    // The pointer stays put while the page scrolls under it, so the loupe
    // would keep showing a spot the pointer has left.
    window.addEventListener("scroll", this.onLeave, { passive: true })
  },

  move(e) {
    if (e.pointerType !== "mouse") return
    if (!this.loupe) this.build()

    // Where the pointer is on the thumbnail, as a share of it, is where it
    // is on the page.
    const box = this.el.getBoundingClientRect()
    const x = clamp01((e.clientX - box.left) / box.width) * this.sheet.width
    const y = clamp01((e.clientY - box.top) / box.height) * this.sheet.height
    const r = SIZE / 2 - BORDER

    // Transforms only, so moving the loupe never costs a layout.
    this.loupe.style.transform = `translate(${e.clientX - SIZE / 2}px, ${e.clientY - SIZE / 2}px)`
    this.page.style.transform = `translate(${r - x * ZOOM}px, ${r - y * ZOOM}px) scale(${ZOOM})`
    this.loupe.style.display = "block"
  },

  hide() {
    if (this.loupe) this.loupe.style.display = "none"
  },
}
