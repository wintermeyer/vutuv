defmodule VutuvWeb.Live.ComposerPanel do
  @moduledoc """
  Folds `VutuvWeb.PostLive.Composer` away behind a "Write a post" button, for
  the pages that keep it folded: **/feed** and the **owner's own profile**.

  A composer cannot fold itself. It is a `Phoenix.LiveComponent`, so the panel
  around it belongs to the host, and the five callbacks that move that panel
  were written twice before this module existed — once in
  `VutuvWeb.PostLive.Feed`, once in `VutuvWeb.UserProfileLive`. The same shape
  as `VutuvWeb.Live.RemoteCounts` and `VutuvWeb.Live.VideoProgress`, for the
  same reason: a host opts in with one line and handles nothing.

  Getting it wrong is not a cosmetic miss. The composer's corner ✕ carries no
  `phx-target`, so `close-composer` bubbles to the host; a host that declares
  itself collapsible (`host={:feed}` / `host={:profile}`) and forgets the
  clause takes the LiveView down on the first click. That is what one module
  for both halves prevents.

  ## Using it

      socket |> ComposerPanel.attach() |> ComposerPanel.assign_draft(user)

  `attach/1` takes the two events and the three messages. `assign_draft/2`
  reads the stored draft once and opens the panel when there is one — hand it
  on as `preloaded_draft={{:loaded, @draft}}` so the composer skips its own
  identical query. A host that reads the draft for other reasons (the feed
  carries it in its `MountHandoff` payload) can assign the pair itself with
  `open_for_draft/2` instead.

  ## The markup half

  Two siblings, both always in the DOM, `hidden` moving between them:

      <div id="composer-trigger" class={@composer_open? && "hidden"}>
        <.compose_button />
      </div>
      <div id="composer-panel" class={!@composer_open? && "hidden"}>
        <.live_component module={VutuvWeb.PostLive.Composer} id="composer" … />
      </div>

  Never an `:if`. An element appearing or disappearing above the editor makes
  morphdom relocate the siblings below it, and re-parenting a `contenteditable`
  blurs it mid-word (issue #1200). The three ids are the ones
  `assets/js/keyboard_shortcuts.js` and `compose_tab.js` reach for by name, so
  a page carries exactly one of each.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Vutuv.Accounts.User
  alias Vutuv.Posts

  @doc """
  Takes the panel's two events and three messages off the host's hands.

  `open-composer` comes from `<.compose_button>`; `close-composer` from the
  composer's ✕ over an empty composer. The three messages are the composer
  saying what it did to a draft: it found one after a reconnect
  (`:composer_drafting`, issue #1130 — form recovery puts the text back while
  the panel would stay folded), the reader kept it (`:composer_closed`) or
  threw it away (`:composer_discarded`).
  """
  def attach(socket) do
    socket
    |> attach_hook(:composer_panel_events, :handle_event, &handle_event/3)
    |> attach_hook(:composer_panel_info, :handle_info, &handle_info/2)
  end

  @doc """
  Reads this member's stored new-post draft and opens the panel over it.

  One indexed row. Text hidden behind a folded panel is indistinguishable from
  text that was thrown away (issue #1148), so a draft decides the opening state
  — resolved here rather than announced by the composer, so the disconnected
  render already agrees and the panel never flickers open.
  """
  def assign_draft(socket, %User{} = user), do: open_for_draft(socket, Posts.get_draft(user))

  def assign_draft(socket, _anonymous), do: open_for_draft(socket, nil)

  @doc "The same two assigns from a draft the host has already read."
  def open_for_draft(socket, draft) do
    socket
    |> assign(:draft, draft)
    |> assign(:composer_open?, draft != nil)
  end

  @doc """
  Folds the panel from the host's own code — what a host does once the post it
  was holding exists, which it learns from `Posts`' `{:new_post, …}` broadcast
  rather than from the composer.
  """
  def collapse(socket), do: assign(socket, :composer_open?, false)

  # A lifecycle hook answers with the socket itself, not a `{:noreply, …}`
  # tuple — `:halt` here means "handled, do not call the host's own callback".
  defp handle_event("open-composer", _params, socket), do: {:halt, open(socket)}
  defp handle_event("close-composer", _params, socket), do: {:halt, collapse(socket)}
  defp handle_event(_other, _params, socket), do: {:cont, socket}

  defp handle_info({:composer_drafting, _id}, socket), do: {:halt, open(socket)}
  defp handle_info({:composer_closed, _id}, socket), do: {:halt, collapse(socket)}
  defp handle_info({:composer_discarded, _id}, socket), do: {:halt, collapse(socket)}
  defp handle_info(_other, socket), do: {:cont, socket}

  defp open(socket), do: assign(socket, :composer_open?, true)
end
