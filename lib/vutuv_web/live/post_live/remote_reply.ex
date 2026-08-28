defmodule VutuvWeb.PostLive.RemoteReply do
  @moduledoc """
  Answering a reply that came from another network (issue #1070) — the sibling of
  `VutuvWeb.PostLive.Reply`: the reply being answered above (read-only, in its own
  remote card) and the same composer below.

  Two things it does that the local reply page does not.

  **It says where the words are going.** A member who has never heard of Mastodon
  must not discover afterwards that their answer left the site, so the page states
  it plainly before they type: the answer goes to that person on their own server
  and to the member's Fediverse followers, and it is a public post on vutuv too.

  **It explains a refusal instead of hiding the action.** The "Reply" link shows
  on every public remote reply for every signed-in member, including one who has
  not switched Fediverse participation on — hiding it would leave them with no way
  to find out that the capability exists. So `:not_federating` is not a dead end
  here: the page explains what the setting does and links to `/settings/fediverse`.
  Every other refusal is a hard no and sends them back with a plain-language
  reason.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.PostComponents

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Note
  alias Vutuv.Posts
  alias VutuvWeb.Live.InitAssigns

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    viewer = socket.assigns.current_user
    note = Fediverse.get_note(id)

    if note && visible?(note, viewer) do
      {:ok, assign_gate(socket, note, viewer)}
    else
      {:ok, InitAssigns.not_found(socket)}
    end
  end

  # The same rule `Vutuv.Fediverse.list_notes/2` enforces for the thread: a public
  # reply is everybody's, a private one is its addressee's alone. Answering a
  # private one is refused separately (`:note_not_public`) — this is only about
  # whether the page may show it at all, so existence never leaks.
  defp visible?(%Note{} = note, viewer) do
    Note.public?(note) or
      match?(%Posts.Post{user_id: id} when id == viewer.id, Posts.get_post(note.post_id))
  end

  defp assign_gate(socket, %Note{} = note, viewer) do
    socket =
      socket
      |> assign(:page_title, gettext("Reply to %{handle}", handle: Note.display_handle(note)))
      |> assign(:note, note)
      |> assign(:post, Posts.get_post(note.post_id))

    case Fediverse.check_remote_reply(viewer, note) do
      :ok ->
        assign(socket, :refusal, nil)

      # The one refusal the member can act on, so it gets the page rather than a
      # redirect.
      {:error, :not_federating} ->
        assign(socket, :refusal, :not_federating)

      {:error, reason} ->
        socket
        |> put_flash(:error, answer_refusal_message(reason))
        |> redirect(to: Posts.path(socket.assigns.post))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.remote_answer_page
      id="remote-reply"
      handle={Note.display_handle(@note)}
      refusal={@refusal}
      explanation={
        gettext(
          "This reply was written on another network. Answering it means sending your words to that network, which vutuv only does for members who have switched Fediverse participation on."
        )
      }
      back_href={@post && Posts.path(@post)}
      back_label={gettext("Back to the conversation")}
    >
      <:target>
        <%!-- Whole, not clamped: nobody should have to open a "Read more" to
        see what they are answering. --%>
        <.remote_reply_card mode={:full} note={@note} viewer={@current_user} />
      </:target>
      <:composer>
        <.live_component
          module={VutuvWeb.PostLive.Composer}
          id="composer"
          current_user={@current_user}
          post={nil}
          parent={nil}
          remote_note={@note}
        />
      </:composer>
    </.remote_answer_page>
    """
  end
end
