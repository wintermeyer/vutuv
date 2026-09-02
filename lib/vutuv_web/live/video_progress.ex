defmodule VutuvWeb.Live.VideoProgress do
  @moduledoc """
  Brings a clip's progress to the composer that holds it (issue #1911).

  `VutuvWeb.PostLive.Composer` draws the tile, and a LiveComponent has no
  process of its own — a subscription made inside one would land its messages
  in the host LiveView's `handle_info/2`, which the host never wrote. So the
  listening happens once **per page**, here, and each `{:post_video, …}` is
  forwarded to the composer that registered that clip (`register/2`). The same
  shape as `VutuvWeb.Live.RemoteCounts`, for the same reason: a host opts in
  with one line and handles nothing.

  Two entry points, because the hosts come in two kinds: a routed page (the
  reply and remote-answer pages) declares `on_mount(VutuvWeb.Live.VideoProgress)`
  after `Live.InitAssigns` has assigned `:current_user`; an embedded page (the
  feed, an organization's page) has no on_mount that sees the user and calls
  `attach/2` from its mount instead. Connected sockets only — the dead render
  reads no messages.

  The message goes on to the host after the forward (`:cont`), so the feed's
  waiting card, which draws from the same broadcast, sees it too.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, send_update: 2]

  alias Vutuv.Accounts.User
  alias Vutuv.Videos
  alias VutuvWeb.PostLive.Composer

  def on_mount(:default, _params, _session, socket),
    do: {:cont, attach(socket, socket.assigns[:current_user])}

  @doc "Subscribes the (connected) host to the member's clips and forwards their progress."
  def attach(socket, %User{id: user_id}) do
    if connected?(socket) do
      Videos.subscribe(user_id)

      socket
      |> assign(:video_composers, %{})
      |> attach_hook(:video_progress, :handle_info, &forward/2)
    else
      socket
    end
  end

  def attach(socket, _anonymous), do: socket

  @doc """
  Tells the host which clip a composer holds, so its progress is forwarded
  there; `nil` withdraws the registration. Called from the component, which
  runs in the host's process.
  """
  def register(composer_id, video_id), do: send(self(), {:composer_video, composer_id, video_id})

  defp forward({:composer_video, composer_id, video_id}, socket) do
    composers =
      if video_id,
        do: Map.put(socket.assigns.video_composers, composer_id, video_id),
        else: Map.delete(socket.assigns.video_composers, composer_id)

    {:halt, assign(socket, :video_composers, composers)}
  end

  defp forward({:post_video, %{id: video_id} = summary}, socket) do
    for {composer_id, ^video_id} <- socket.assigns.video_composers do
      send_update(Composer, id: composer_id, video_event: summary)
    end

    {:cont, socket}
  end

  defp forward(_message, socket), do: {:cont, socket}
end
