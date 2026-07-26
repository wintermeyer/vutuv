defmodule VutuvWeb.PostLive.Reply do
  @moduledoc """
  Reply page — the parent post (read-only preview) above the same composer
  as the feed. Only visible, **public** parents can be answered
  (`Vutuv.Posts.create_reply/3` enforces the same rule); everything else is
  sent away with the unknown-id flash, so existence never leaks.

  **Quoting a passage** (issue #1114): a reader who marks part of a post before
  pressing Reply arrives here with that text in the `quote` parameter, and the
  composer opens with it as a Markdown blockquote. The selection is client-side
  by nature, so `assets/js/app.js` puts it on the Reply link at click time; the
  parameter is untrusted text like any other and goes through
  `VutuvWeb.Markdown.blockquote/1`, which normalizes and caps it. Nothing here
  ties the quote to the parent — the reply card already names the post it
  answers, with its author's avatar and a link to it.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.PostComponents

  alias Vutuv.Posts
  alias VutuvWeb.Markdown

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    user = socket.assigns.current_user
    parent = Posts.get_post(id)

    if parent && Posts.visible_to?(parent, user) && not Posts.restricted?(parent) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Reply"))
       |> assign(:parent, parent)
       |> assign(:initial_body, Markdown.blockquote(params["quote"]))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Sorry, that page could not be found."))
       |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="post-reply" class="py-6">
      <div class="mx-auto max-w-2xl space-y-4">
        <h1 class="text-2xl font-bold text-slate-800 dark:text-slate-100">
          {gettext("Reply to %{handle}", handle: "@" <> @parent.user.username)}
        </h1>

        <%!-- quotable={false}: this card's own Reply link leads back to this
        page, so arming it would let a second selection reload the page and
        throw away whatever has been typed below. --%>
        <.post_card
          post={@parent}
          viewer={@current_user}
          mode={:preview}
          conn_or_socket={@socket}
          quotable={false}
        />

        <.live_component
          module={VutuvWeb.PostLive.Composer}
          id="composer"
          current_user={@current_user}
          post={nil}
          parent={@parent}
          initial_body={@initial_body}
        />

        <.link
          href={Posts.path(@parent)}
          class="text-sm font-semibold text-brand-600 hover:text-brand-700"
        >
          {gettext("Back to the post")}
        </.link>
      </div>
    </div>
    """
  end
end
