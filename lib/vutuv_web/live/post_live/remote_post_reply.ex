defmodule VutuvWeb.PostLive.RemotePostReply do
  @moduledoc """
  Answering a post by an account the member follows on another network (issue
  #1165) — the sibling of `VutuvWeb.PostLive.RemoteReply`, which answers a reply
  that arrived under one of the member's own posts.

  The two pages look and behave the same on purpose, and share one definition of
  it (`VutuvWeb.PostComponents.remote_answer_page/1`): the thing being answered
  above in its own remote card, the plain sentence about where the words are
  going stated **before** anybody types, the same composer below, and the same
  treatment of a member who has not switched Fediverse participation on (the
  page explains and links to the setting rather than hiding the action).

  What differs is underneath. There is no vutuv post beneath this one: the post
  being answered lives entirely on somebody else's server, so what gets created
  is a **top-level vutuv post** carrying the remote-target sidecar. Hence "Back
  to the feed" rather than "Back to the conversation" — there is no conversation
  here to go back to, and the answer's own permalink is where the member lands
  after sending.

  One gate is stricter than the reply page's: a **followers-only** post cannot be
  answered at all. The answer is a public vutuv post, and republishing the
  audience its author deliberately narrowed is not ours to do — so the card
  offers no Reply there in the first place, and this page refuses if somebody
  reaches it anyway.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.PostComponents

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    viewer = socket.assigns.current_user
    post = Fediverse.get_remote_post(id)

    # Readable, not merely present: this page shows the post it is about, so the
    # same rule that decides whether a member may see it at all decides whether
    # this page exists for them. Anything else is a 404, so nothing leaks.
    if post && Fediverse.remote_post_readable?(post, viewer) do
      {:ok, assign_gate(socket, post, viewer)}
    else
      {:ok, not_found(socket)}
    end
  end

  defp assign_gate(socket, %RemotePost{} = post, viewer) do
    handle = RemoteAccount.display_handle(post.remote_account)

    socket =
      socket
      |> assign(:page_title, gettext("Reply to %{handle}", handle: handle))
      |> assign(:remote_post, post)
      |> assign(:handle, handle)

    case Fediverse.check_remote_post_reply(viewer, post) do
      :ok ->
        assign(socket, :refusal, nil)

      # The one refusal the member can act on, so it gets the page rather than
      # a redirect: hiding it would leave them with no way to find out that
      # answering exists and is one setting away.
      {:error, :not_federating} ->
        assign(socket, :refusal, :not_federating)

      {:error, reason} ->
        socket
        |> put_flash(:error, answer_refusal_message(reason))
        |> redirect(to: ~p"/feed")
    end
  end

  defp not_found(socket) do
    socket
    |> put_flash(:error, gettext("Sorry, that page could not be found."))
    |> redirect(to: ~p"/")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.remote_answer_page
      id="remote-post-reply"
      handle={@handle}
      refusal={@refusal}
      explanation={
        gettext(
          "This post was written on another network. Answering it means sending your words to that network, which vutuv only does for members who have switched Fediverse participation on."
        )
      }
      back_href={~p"/feed"}
      back_label={gettext("Back to the feed")}
    >
      <:target>
        <.remote_post_card remote_post={@remote_post} viewer={@current_user} />
      </:target>
      <:composer>
        <.live_component
          module={VutuvWeb.PostLive.Composer}
          id="composer"
          current_user={@current_user}
          post={nil}
          parent={nil}
          remote_post={@remote_post}
        />
      </:composer>
    </.remote_answer_page>
    """
  end
end
