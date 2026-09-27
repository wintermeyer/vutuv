// The post composer's one way in for a picture, a clip or a file. The member
// picks or drops whatever they have; this hook decides which of the three
// LiveView uploads it belongs to by what the browser says it is, so there is
// one button and one drop area instead of three pickers.
//
// The three live file inputs still exist (hidden, in the form): each queue
// keeps its own limits, its own progress and its own server-side pipeline.
// What moves here is only the choice of queue. A type the browser cannot name
// goes to the files queue, where `Vutuv.Attachments.Format` reads the bytes and
// refuses what it does not know, with a sentence the composer shows.
//
// Drops into the prose editor never reach this: the editor swallows a picture
// dropped there to place it inline, and stops the event.

const queueFor = (file, enabled) => {
  const type = file.type || ""
  if (type.startsWith("image/")) return "images"
  if (type.startsWith("video/") && enabled.video) return "video"
  return enabled.attachments ? "attachments" : "images"
}

const hasFiles = (event) => [...(event.dataTransfer?.types || [])].includes("Files")

export const ComposerFiles = {
  mounted() {
    this.depth = 0
    this.onDragEnter = (e) => {
      if (!hasFiles(e)) return
      e.preventDefault()
      this.depth += 1
      this.el.classList.add("is-dragging")
    }
    this.onDragOver = (e) => {
      if (hasFiles(e)) e.preventDefault()
    }
    this.onDragLeave = (e) => {
      if (!hasFiles(e)) return
      this.depth = Math.max(0, this.depth - 1)
      if (this.depth === 0) this.el.classList.remove("is-dragging")
    }
    this.onDrop = (e) => {
      this.depth = 0
      this.el.classList.remove("is-dragging")
      if (!hasFiles(e)) return
      e.preventDefault()
      this.route(e.dataTransfer.files)
    }
    this.onPick = (e) => {
      const input = e.target.closest("[data-composer-pick]")
      if (!input) return
      // Not the form's business: without this the change would also go out
      // as a `validate` carrying nothing.
      e.stopPropagation()
      this.route(input.files)
      input.value = ""
    }

    this.el.addEventListener("dragenter", this.onDragEnter)
    this.el.addEventListener("dragover", this.onDragOver)
    this.el.addEventListener("dragleave", this.onDragLeave)
    this.el.addEventListener("drop", this.onDrop)
    this.el.addEventListener("change", this.onPick, true)
    // A picture let go over the prose editor never reaches `onDrop`: the
    // editor stops the event to place it inline. Caught on the way down
    // instead, so the drop area does not stay blue.
    this.reset = () => {
      this.depth = 0
      this.el.classList.remove("is-dragging")
    }
    window.addEventListener("drop", this.reset, true)
    window.addEventListener("dragend", this.reset, true)
  },

  destroyed() {
    this.el.removeEventListener("dragenter", this.onDragEnter)
    this.el.removeEventListener("dragover", this.onDragOver)
    this.el.removeEventListener("dragleave", this.onDragLeave)
    this.el.removeEventListener("drop", this.onDrop)
    this.el.removeEventListener("change", this.onPick, true)
    window.removeEventListener("drop", this.reset, true)
    window.removeEventListener("dragend", this.reset, true)
  },

  route(fileList) {
    const files = [...(fileList || [])]
    if (files.length === 0) return
    const enabled = {
      video: this.el.dataset.videoUploads === "true",
      attachments: this.el.dataset.fileUploads === "true",
    }
    const queues = {}
    for (const file of files) {
      const name = queueFor(file, enabled)
      ;(queues[name] ||= []).push(file)
    }
    for (const [name, queued] of Object.entries(queues)) {
      this.uploadTo(this.el, name, queued)
    }
  },
}
