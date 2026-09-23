// The reply inbox's hover preview on /notifications: a pointer resting on a
// row asks the server for the whole post (`preview`), leaving the row closes
// it again (`preview_close`). The preview is rendered inside the row, so moving
// the pointer onto it does not count as leaving.
//
// Only for a real hovering pointer (`canHover`, the gate the bell's preview
// uses too). A touch screen fires mouseenter on a tap, and a preview popping
// over the row the finger just pressed would cover the very button it meant;
// there the teaser unfolds in place instead.
//
// The delay keeps a pointer that merely sweeps across the list from asking
// the server for every row it crosses.
import { canHover } from "./util"

const OPEN_DELAY = 350

export const ReplyPreview = {
  mounted() {
    this.timer = null
    this.open = false

    this.onEnter = () => {
      if (!canHover()) return
      clearTimeout(this.timer)
      this.timer = setTimeout(() => {
        this.open = true
        this.pushEvent("preview", { id: this.el.dataset.previewId })
      }, OPEN_DELAY)
    }

    this.onLeave = () => {
      clearTimeout(this.timer)
      if (!this.open) return
      this.open = false
      this.pushEvent("preview_close", { id: this.el.dataset.previewId })
    }

    this.el.addEventListener("mouseenter", this.onEnter)
    this.el.addEventListener("mouseleave", this.onLeave)
  },

  destroyed() {
    clearTimeout(this.timer)
    this.el.removeEventListener("mouseenter", this.onEnter)
    this.el.removeEventListener("mouseleave", this.onLeave)
  },
}
