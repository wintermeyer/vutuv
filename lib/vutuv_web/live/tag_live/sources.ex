defmodule VutuvWeb.TagLive.Sources do
  @moduledoc """
  The source chip and its panel beside the follow button on a tag page (issue
  #2157).

  The feed's tag card is where a member changes the servers a followed tag
  comes from, and it lives in a rail a phone never shows. The tag page is where
  a phone reader follows a tag, so the same chip and the same panel
  (`VutuvWeb.PostLive.TagSources`) stand there too, on every screen size.

  Embedded by `VutuvWeb.TagController.show/2` via `live_render`, only when
  `source_count/3` has an answer for the request. The dead render draws the
  chip from the count the controller handed over; the socket resolves the
  member from the cookie's `session_token`
  (`VutuvWeb.Live.InitAssigns.assign_embedded/2`), never from the curated
  `user_id`, and asks `source_count/3` again before it mounts the panel a press
  could write through.
  """

  use Phoenix.LiveView

  import VutuvWeb.PostLive.TagSources, only: [source_chip: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias Vutuv.Tags
  alias Vutuv.Tags.SourceServers
  alias Vutuv.Tags.Tag
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.PostLive.TagSources

  @doc """
  How many servers feed `tag` for this viewer, or `nil` when the chip does not
  belong on the page.

  It belongs there only for a member who follows the tag themselves, on an
  installation that reads other servers. While the member speaks for a page the
  follow button beside it shows the page's subscription (issue #1336), and a
  chip about the member's own follow next to it would contradict it.
  """
  def source_count(%User{} = member, nil = _acting_as, %Tag{} = tag) do
    with true <- SourceServers.enabled?(),
         %{} = follow <- Tags.tag_follow(member, tag.id) do
      length(Tags.tag_follow_sources(follow))
    else
      _ -> nil
    end
  end

  def source_count(_member, _acting_as, _tag), do: nil

  @impl true
  def mount(_params, session, socket) do
    tag = load_tag(session["tag_id"])

    socket =
      if connected?(socket) do
        socket = InitAssigns.assign_embedded(socket, session)
        %{current_user: member, acting_as: acting_as} = socket.assigns
        count = source_count(member, acting_as, tag)

        socket
        |> assign(:count, count)
        # Only a member the token vouches for, and who follows the tag, gets a
        # panel to write through.
        |> assign(:member, count && member)
      else
        socket |> assign(:count, tag && session["source_count"]) |> assign(:member, nil)
      end

    {:ok, socket |> assign(:tag, tag) |> assign(:open_id, nil)}
  end

  defp load_tag(id) when is_binary(id), do: Repo.get(Tag, id)
  defp load_tag(_id), do: nil

  # Every press is the panel's; the root has nothing to act on. A pushed event
  # that reaches it anyway (a socket that resolved no member) is ignored rather
  # than crashing the page's one live corner.
  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({TagSources, {:panel, tag_id}}, socket) do
    {:noreply, assign(socket, :open_id, tag_id)}
  end

  def handle_info({TagSources, {:sources_changed, _tag_id}}, socket) do
    %{member: member, acting_as: acting_as, tag: tag} = socket.assigns
    {:noreply, assign(socket, :count, source_count(member, acting_as, tag))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # The container is `display: contents` (see the tag page), so the chip sits in
  # the header's row beside the follow button and the panel takes a row of its
  # own under it, full width, on every screen.
  @impl true
  def render(assigns) do
    ~H"""
    <%!-- The same box as the follow pill beside it (1px border, 6px padding, a
    16px line), so the two stand on one line. --%>
    <div :if={@count} class="flex items-center border border-transparent py-1.5">
      <.source_chip tag={@tag} count={@count} open?={@open_id == @tag.id} />
    </div>
    <div :if={@member} class="w-full">
      <.live_component module={TagSources} id="tag-sources" user={@member} tags={[@tag]} />
    </div>
    """
  end
end
