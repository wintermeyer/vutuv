defmodule VutuvWeb.Live.ExternalPostActionsComponent do
  @moduledoc """
  Resolves a tag find only after a member presses an action. The tag fetch path
  keeps its text-only rows; a deliberate press uses the ordinary URL lookup.
  """

  use VutuvWeb, :live_component
  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Fediverse
  alias VutuvWeb.PostLive.RemoteActionsComponent

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:url, assigns.url)
     |> assign(:viewer, assigns.viewer)
     |> assign_new(:post, fn -> nil end)
     |> assign_new(:error, fn -> nil end)}
  end

  @impl true
  def handle_event("act", %{"act" => act}, socket)
      when act in ["like", "reply", "repost", "bookmark"] do
    case Fediverse.look_up_post(socket.assigns.viewer, socket.assigns.url) do
      {:ok, post} -> act(socket, post, act)
      _ -> {:noreply, assign(socket, :error, gettext("This post could not be loaded."))}
    end
  end

  defp act(socket, post, "reply") do
    {:noreply, push_navigate(socket, to: ~p"/system/fediverse/reply/post/#{post.id}")}
  end

  defp act(socket, post, act) do
    # The existing component reads the resulting mark on mount and owns every
    # later press, including undo. The first press is already the requested act.
    case Fediverse.toggle_engagement(socket.assigns.viewer, post, act, true) do
      {:ok, _} ->
        {:noreply, socket |> assign(:post, post) |> assign(:error, nil)}

      {:error, _} ->
        {:noreply, assign(socket, :error, gettext("This action could not be completed."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= if @post do %>
        <.live_component
          module={RemoteActionsComponent}
          id={"external-resolved-#{@id}"}
          subject={@post}
          viewer={@viewer}
        />
      <% else %>
        <div data-action-bar class="-mx-2 mt-3 flex items-center justify-between gap-2 text-slate-600 dark:text-slate-400">
          <button :for={{act, label} <- [{"like", gettext("Like")}, {"reply", gettext("Reply")}, {"repost", gettext("Repost")}, {"bookmark", gettext("Bookmark")}]} type="button" data-external-action={act} phx-click="act" phx-value-act={act} phx-target={@myself} class="min-h-10 rounded-lg px-2 hover:bg-slate-100 dark:hover:bg-slate-800">
            {label}
          </button>
        </div>
      <% end %>
      <p :if={@error} role="alert" class="mt-2 text-sm text-red-700 dark:text-red-300">{@error}</p>
    </div>
    """
  end
end
