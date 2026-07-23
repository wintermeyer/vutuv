defmodule VutuvWeb.PostLive.Edit do
  @moduledoc """
  Edit page for a post — the same composer as the feed, prefilled. Only the
  author may open it; everyone else is sent away with the same flash an
  unknown id gets (no existence leak). The post card's ⋯ menu carries
  Edit/Delete wherever the post renders; this page keeps its own delete
  button so the destructive action also sits on the edit surface.

  Editing is time- and engagement-limited (issue #1023, `Vutuv.Posts.editable?/1`):
  once the post is older than `Posts.edit_window_minutes/0`, or somebody has
  liked, reposted or answered it, this page redirects to the post and says why. Deleting
  stays possible at any time.

  A single-URL, image-less post also gets an auto-captured link screenshot
  (`Vutuv.Posts.Screenshots`). When that capture is bad (a cookie banner
  covering the page, say) the author can remove it here — a "Remove screenshot"
  control shown only while a captured screenshot is on the card. Removing it
  tombstones the screenshot so it stops rendering and is not re-captured on a
  plain re-save (`Vutuv.Posts.dismiss_screenshot/1`).
  """

  use VutuvWeb, :live_view

  alias Vutuv.Posts
  alias Vutuv.Posts.PostScreenshot

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns[:current_user]
    post = Posts.get_post(id)

    cond do
      is_nil(post) or not Posts.author?(post, user) ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Sorry, that page could not be found."))
         |> redirect(to: ~p"/")}

      not Posts.editable?(post) ->
        {:ok,
         socket
         |> put_flash(:error, edit_closed_message(post))
         |> redirect(to: Posts.path(post))}

      true ->
        {:ok,
         socket
         |> assign(:page_title, gettext("Edit post"))
         |> assign(:post, post)
         |> assign(:screenshot, ready_screenshot(post))}
    end
  end

  # Why the door is shut, in the author's words. `Posts.edit_window_open?/1` is
  # the no-query half of the check, so it tells the two cases apart without a
  # second round trip.
  defp edit_closed_message(post) do
    if Posts.edit_window_open?(post) do
      gettext("This post can no longer be edited: someone has liked, reposted or answered it.")
    else
      gettext(
        "This post can no longer be edited. Posts stay editable for %{minutes} minutes after publishing.",
        minutes: Posts.edit_window_minutes()
      )
    end
  end

  @impl true
  def handle_event("remove-screenshot", _params, socket) do
    {:ok, post} = Posts.dismiss_screenshot(socket.assigns.post)

    {:noreply,
     socket
     |> assign(:post, post)
     |> assign(:screenshot, ready_screenshot(post))
     |> put_flash(:info, gettext("Screenshot removed."))}
  end

  # The captured, released link screenshot to offer for removal, or nil. Mirrors
  # the card's own gate (`VutuvWeb.PostComponents`): only a `ready` row that the
  # AI scan has released is shown, so this is exactly what the reader sees.
  defp ready_screenshot(%{screenshot: %PostScreenshot{} = ps}) do
    if PostScreenshot.ready?(ps), do: ps
  end

  defp ready_screenshot(_post), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div id="post-edit" class="py-6">
      <div class="mx-auto max-w-2xl space-y-4">
        <h1 class="text-2xl font-bold text-slate-800 dark:text-slate-100">
          {gettext("Edit post")}
        </h1>

        <%!-- The rules of the edit window, said once and up front, so a closed
        door later is no surprise (issue #1023). --%>
        <p id="edit-window-hint" class="text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "A post stays editable for %{minutes} minutes, and only until someone likes, reposts or answers it. You can delete it at any time.",
            minutes: Posts.edit_window_minutes()
          )}
        </p>

        <.live_component
          module={VutuvWeb.PostLive.Composer}
          id="composer"
          current_user={@current_user}
          post={@post}
        />

        <.card :if={@screenshot} id="post-screenshot-editor">
          <.section_title>{gettext("Link preview screenshot")}</.section_title>
          <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
            {gettext(
              "This screenshot was captured automatically from the link in your post. If it turned out wrong (for example a cookie banner covering the page), you can remove it."
            )}
          </p>

          <div class="mt-3 flex flex-wrap items-start gap-4">
            <img
              src={Vutuv.Screenshot.url({@screenshot.screenshot, @screenshot}, :thumb)}
              width="200"
              height="132"
              alt=""
              class="aspect-[400/264] w-40 shrink-0 rounded-lg object-cover ring-1 ring-slate-200 dark:ring-slate-800"
            />
            <.button
              id="remove-screenshot"
              variant="danger"
              phx-click="remove-screenshot"
              data-confirm={gettext("Remove this screenshot from your post?")}
            >
              {gettext("Remove screenshot")}
            </.button>
          </div>
        </.card>

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
