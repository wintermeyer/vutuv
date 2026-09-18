// The booking calendar's hover preview: with a week or a month chosen, moving
// over a day marks the whole stretch it would occupy.
//
// Deliberately client-side. The point of the mark is to let somebody FIND a
// free stretch by running their eye along the grid, and a round trip per day
// hovered would make that the slowest thing on the page — while the answer is
// already in the DOM, because the server rendered exactly the days that may
// start a block as buttons.
//
// Only the resting state is the server's: which days are selectable, and which
// are in the picked block. This adds one class and takes it off again, so a
// LiveView patch landing mid-hover can never leave a day looking booked.
export const AdCalendar = {
  mounted() {
    this.days = () => Math.max(1, parseInt(this.el.dataset.days, 10) || 1)

    // Every cell that stands for a real day, in calendar order across the
    // months, so a block may run over a month boundary.
    this.cells = () => Array.from(this.el.querySelectorAll("[data-day]"))

    this.clear = () => {
      for (const cell of this.cells()) cell.classList.remove("is-block-hover")
    }

    this.preview = (start) => {
      const cells = this.cells()
      const from = cells.indexOf(start)
      if (from === -1) return

      this.clear()
      // Walk by DATE, not by index: an unavailable day is in the grid too, so
      // counting cells would mark a stretch that skips over nothing and
      // silently ends a day early after a leading gap.
      const first = start.dataset.day
      for (let i = 0; i < this.days(); i++) {
        const want = addDays(first, i)
        const cell = cells.find((c) => c.dataset.day === want)
        if (!cell) return
        cell.classList.add("is-block-hover")
      }
    }

    this.onOver = (event) => {
      const cell = event.target.closest("[data-day]")
      // Only a day that may START a block previews one; the server renders
      // those as buttons and everything else as a span.
      if (cell && cell.tagName === "BUTTON" && this.el.contains(cell)) this.preview(cell)
      else this.clear()
    }

    this.el.addEventListener("pointerover", this.onOver)
    this.el.addEventListener("pointerleave", this.clear)
    this.el.addEventListener("focusin", this.onOver)
  },

  updated() {
    // The length or the selection changed under the pointer; the server's
    // render is the truth again.
    this.clear()
  },

  destroyed() {
    this.el.removeEventListener("pointerover", this.onOver)
    this.el.removeEventListener("pointerleave", this.clear)
    this.el.removeEventListener("focusin", this.onOver)
  },
}

// ISO date plus n days, without pulling in a date library for one line.
function addDays(iso, n) {
  const date = new Date(iso + "T00:00:00Z")
  date.setUTCDate(date.getUTCDate() + n)
  return date.toISOString().slice(0, 10)
}
