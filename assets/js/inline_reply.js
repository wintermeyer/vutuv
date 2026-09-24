// The Reply inside a card on /notifications opens the composer under that card
// instead of leaving for the reply page: somebody working through the replies
// that came in since their last look should not leave the list five times.
//
// The card is the feed's own (`post_card/1`, `remote_reply_card/1`), whose
// Reply is a plain link to the reply page. This hook takes the click on the
// way down (capture phase, before LiveView's own link handling) and asks the
// page for the composer instead, so without JavaScript the link still does
// what it always did. A modified click (new tab, new window) is left alone.
const REPLY_LINK = 'a[href^="/posts/"][href$="/reply"], a[href^="/system/fediverse/reply/"]'

export const InlineReply = {
  mounted() {
    this.onClick = (event) => {
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)
        return

      const link = event.target.closest(REPLY_LINK)
      if (!link || !this.el.contains(link)) return

      event.preventDefault()
      event.stopPropagation()
      this.pushEvent("compose", { id: this.el.dataset.rowId })
    }

    this.el.addEventListener("click", this.onClick, true)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick, true)
  },
}
