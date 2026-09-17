defmodule VutuvWeb.TagLive.Sources do
  @moduledoc """
  The source chip and its panel beside the follow button on a tag page (issue
  #2157).

  The feed's tag card is where a member changes the servers a followed tag
  comes from, and it lives in a rail a phone never shows. The tag page is where
  a phone reader follows a tag, so the same chip and the same panel
  (`VutuvWeb.PostLive.TagSources`) stand there too, on every screen size.

  Embedded by `VutuvWeb.TagController.show/2` via `live_render`, only when the
  controller has a number for the chip (`chip_count/1`). The dead render draws
  the chip from that number and the tag's public fields in the session
  (`session/2`), so it reads nothing. The socket resolves the member from the
  cookie's `session_token` (`VutuvWeb.Live.InitAssigns.assign_embedded/2`),
  never from the curated `user_id`, and asks for the count again before it
  loads the tag and mounts the panel a press could write through.
  """

  use VutuvWeb, :embedded_live_view

  import VutuvWeb.PostLive.TagSources, only: [source_chip: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias Vutuv.Tags
  alias Vutuv.Tags.SourceServers
  alias Vutuv.Tags.Tag
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.PostLive.TagSources

  @doc """
  The number on the chip, from a follow's source count
  (`Vutuv.Tags.followed_tag_source_count/2`, `nil` when the tag is not
  followed): `nil`, and no chip, on an installation that reads no other server.
  """
  def chip_count(count) when is_integer(count) do
    if SourceServers.enabled?(), do: count
  end

  def chip_count(nil), do: nil

  @doc """
  What the tag page hands the view besides the curated session: the tag's
  public fields and the chip's number, which the dead render draws from.
  """
  def session(%Tag{} = tag, count) do
    %{
      "tag" => %{"id" => tag.id, "name" => tag.name, "slug" => tag.slug},
      "source_count" => count
    }
  end

  @impl true
  def mount(_params, session, socket) do
    socket =
      if connected?(socket),
        do: mount_connected(socket, session),
        else: mount_static(socket, session)

    {:ok, assign(socket, :open_id, nil)}
  end

  defp mount_static(socket, %{"tag" => tag, "source_count" => count}) do
    socket
    |> assign(:tag, %Tag{id: tag["id"], name: tag["name"], slug: tag["slug"]})
    |> assign(:count, count)
    |> assign(:current_user, nil)
  end

  # Only a member the token vouches for, and who follows the tag, gets a panel
  # to write through.
  defp mount_connected(socket, session) do
    socket = InitAssigns.assign_embedded(socket, session)
    %{current_user: member, acting_as: acting_as} = socket.assigns

    with %{"id" => id} <- session["tag"],
         count when is_integer(count) <- source_count(member, acting_as, id),
         %Tag{} = tag <- Repo.get(Tag, id) do
      assign(socket, tag: tag, count: count)
    else
      _ -> assign(socket, tag: nil, count: nil)
    end
  end

  # The chip belongs only to a member who follows the tag themselves. While the
  # member speaks for a page the follow button beside it shows the page's
  # subscription (issue #1336), and a chip about the member's own follow next
  # to it would contradict it.
  defp source_count(%User{} = member, nil = _acting_as, tag_id) when is_binary(tag_id),
    do: chip_count(Tags.followed_tag_source_count(member, tag_id))

  defp source_count(_member, _acting_as, _tag_id), do: nil

  # Every press is the panel's; the root has nothing to act on. A pushed event
  # that reaches it anyway (a socket that resolved no member) is ignored rather
  # than crashing the page's one live corner.
  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({TagSources, {:panel, tag_id}}, socket) do
    {:noreply, assign(socket, :open_id, tag_id)}
  end

  def handle_info({TagSources, {:sources_changed, _tag_id, count}}, socket) do
    {:noreply, assign(socket, :count, count)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # The container is `display: contents` (see the tag page), so the chip sits in
  # the header's row beside the follow button and the panel takes a row of its
  # own under it, full width, on every screen.
  @impl true
  def render(assigns) do
    ~H"""
    <%!-- The follow pill's 30px line (1px border, 6px padding, a 16px line),
    so the two stand on one line; the chip's 40px target overflows it evenly
    above and below. --%>
    <div :if={@count} class="flex h-7.5 items-center">
      <.source_chip tag={@tag} count={@count} open?={@open_id == @tag.id} size={:touch} />
    </div>
    <div :if={@count && @current_user} class="w-full">
      <.live_component module={TagSources} id="tag-sources" user={@current_user} tags={[@tag]} />
    </div>
    """
  end
end
