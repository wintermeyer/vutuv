defmodule VutuvWeb.PostLive.Edit do
  @moduledoc """
  Edit page for a post — the same composer as the feed, prefilled. Only the
  author may open it; everyone else is sent away with the same flash an
  unknown id gets (no existence leak). The post card's ⋯ menu carries
  Edit/Delete wherever the post renders; this page keeps its own delete
  button so the destructive action also sits on the edit surface.
  """

  use VutuvWeb, :live_view

  alias Vutuv.Posts

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns[:current_user]
    post = Posts.get_post(id)

    if user && post && post.user_id == user.id do
      {:ok,
       socket
       |> assign(:page_title, gettext("Edit post"))
       |> assign(:post, post)}
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
    <div id="post-edit" class="py-6">
      <div class="mx-auto max-w-2xl space-y-4">
        <h1 class="text-2xl font-bold text-slate-800 dark:text-slate-100">
          {gettext("Edit post")}
        </h1>

        <.live_component
          module={VutuvWeb.PostLive.Composer}
          id="composer"
          current_user={@current_user}
          post={@post}
        />

        <div class="flex items-center justify-between">
          <.link
            href={Posts.path(@post)}
            class="text-sm font-semibold text-brand-600 hover:text-brand-700"
          >
            {gettext("Back to the post")}
          </.link>

          <.button
            id="delete-post"
            variant="danger"
            href={~p"/posts/#{@post.id}"}
            method="delete"
            data-confirm={gettext("Delete this post permanently?")}
          >
            {gettext("Delete post")}
          </.button>
        </div>
      </div>
    </div>
    """
  end
end
