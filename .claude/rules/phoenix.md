---
paths:
  - "lib/**/*.ex"
---

<!--
  Project note: vutuv is a legacy controller/view/template app and DOES use the
  Phoenix view layer (lib/vutuv_web/views/*, 49 view modules). The generic
  "Phoenix.View no longer is needed, don't use it" rule below comes from upstream
  usage_rules and does NOT apply to this codebase until the view layer is migrated.
  Do not remove existing Phoenix.View usage.
-->

## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it

## LiveView guidelines

- **UI state a member can lose must not live only in socket assigns: a reconnect re-mounts the LiveView and resets it.** A websocket reconnect runs `mount/3` again, so every plain assign drops back to its initial value, and reconnects are ordinary, not exotic: a tab left in the background has its heartbeat throttled by the browser until the transport times out, and a network blip or a blue/green deploy does the same. What makes the resulting bug so confusing is an asymmetry: LiveView's **form recovery** replays a form's `phx-change` with the values still sitting in the DOM, so everything *inside* a form comes back on the server, while the socket state that merely *wraps* that form (an open/collapsed flag, a wizard step, a revealed-section set, a "show more" toggle) does not. The member sees their text intact and the form gone. This shipped as issue #1130: the feed's `composer_open?` collapsed the composer under a half-typed post, so returning from looking something up looked like the draft had been thrown away. So whenever you add a reveal / step / expand flag to a LiveView, ask what it looks like after a re-mount, and derive it from something that survives one (a recovered form field, `handle_params` and the URL, the DB) instead of leaving it at its mount default. In #1130 the composer announces its first content to the feed, which re-opens the panel from the recovered `validate` in the same round trip.

- **Reproduce a reconnect in five seconds instead of waiting for a throttled tab**: in the browser console, `liveSocket.disconnect()` then `liveSocket.connect()`. And to tell a real server re-render from morphdom simply leaving the DOM alone, stamp a client-only sentinel on the attribute first (`el.dataset.someValue = "SENTINEL"`) and watch whether the rejoin overwrites it with the real value. That is what proved form recovery, rather than a stale DOM, was restoring the #1130 draft.

- **Private helpers dropped between two `handle_event/3` (or `handle_info/2`) clauses split the clause group** and fail `compile --warnings-as-errors`, which is a `mix precommit` failure. Put them below the last clause of the group.

- **An element with an `:if` that sits ABOVE a focused editor must live in a wrapper that is always rendered — otherwise the patch that hides it throws the caret out of the editor.** When a conditional element appears or disappears among a parent's children, morphdom does not merely delete or insert it: to get the sibling order right it **relocates** the following keyed siblings (`removeChild` + `insertBefore`, visible as a remove/add pair for the same node in a `MutationObserver`). Re-parenting a `contenteditable` **blurs** it, and LiveView will not put the focus back — its post-patch `DOM.restoreFocus` covers `<input>`/`<textarea>` only (`isTextualInput`), never a contenteditable. For a plain input that is invisible; for the Milkdown composer it means the caret vanishes mid-sentence, every keystroke after it is silently dropped, and the next click puts the cursor somewhere else — which is what the member reports as a **jumping cursor**. It bit twice, both times from something outside the writer's control: the post composer's "Picked up where you left off" notice stepping aside on the first edit of a restored draft, and the messages page raising the other side's typing bubble above the composer. The fix is one always-rendered wrapper (`#composer-notice`, `#typing-slot`) with the `:if` on its child, so the patch swaps a node *inside* the wrapper and the form below never moves; guard it with a test that asserts the wrapper renders in **both** states, or someone will fold the "empty div" away. The hook cannot repair this after the fact: morphdom moves the ancestor before it descends into the editor, so the hook's own `beforeUpdate/0` already sees `document.activeElement` at `<body>`. When a caret misbehaves, watch it with a `focusout` listener plus a `MutationObserver` on the container and look for a same-node remove/add pair — do not start by suspecting the editor library.
