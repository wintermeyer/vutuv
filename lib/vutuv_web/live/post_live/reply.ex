defmodule VutuvWeb.PostLive.Reply do
  @moduledoc """
  Reply page — the parent post (read-only preview) above the same composer
  as the feed. Only visible, **public** parents can be answered
  (`Vutuv.Posts.create_reply/3` enforces the same rule); everything else is
  sent away with the unknown-id flash, so existence never leaks.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.PostComponents

  alias Vutuv.Posts

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user
    parent = Posts.get_post(id)

    if parent && Posts.visible_to?(parent, user) && not Posts.restricted?(parent) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Reply"))
       |> assign(:parent, parent)}
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

        <.post_card post={@parent} viewer={@current_user} mode={:preview} conn_or_socket={@socket} />

        <.live_component
          module={VutuvWeb.PostLive.Composer}
          id="composer"
          current_user={@current_user}
          post={nil}
          parent={@parent}
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
