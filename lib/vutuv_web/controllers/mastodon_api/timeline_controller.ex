defmodule VutuvWeb.MastodonApi.TimelineController do
  @moduledoc """
  The authenticated home timeline for a member or organization identity.

  The merged feed paginates by a `{timestamp, seen ids}` cursor rather than by a
  single id, because it interleaves sources that share no id space. A Mastodon
  client only ever hands back an id, so the boundary is read out of that id:
  `Vutuv.UUIDv7` embeds its creation millisecond, which is exactly the timestamp
  the cursor wants. The seen-id list is the same uuid under each prefix a source
  can give it, so the boundary entry itself is not served twice — a wrong guess
  costs nothing, since those ids are unique.
  """

  use VutuvWeb, :controller

  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Posts
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.Timeline
  alias Vutuv.UUIDv7
  alias VutuvWeb.MastodonApi.Pagination

  # Every prefix a feed source stamps onto an entry id (Vutuv.Posts and
  # Vutuv.Fediverse). Kept here rather than exported, because this is the only
  # caller that has to reverse the mapping.
  @entry_prefixes ~w(post repost tagpost boost remote)

  def home(conn, params) do
    page = Pagination.params(strip_prefixes(params))
    entries = load(conn, page)

    conn
    |> Pagination.link_header(Enum.map(entries, &boundary_id/1), page)
    |> json(Presenter.statuses(entries, viewer(conn)))
  end

  # A status from another network is rendered with a prefixed id
  # (`remote-<uuid>`), and that is what a client hands back. Both the boundary
  # we read and the one we advertise are the bare uuid underneath, which is the
  # part that carries the timestamp.
  defp strip_prefixes(params) do
    Enum.reduce(~w(max_id since_id min_id), params, fn key, acc ->
      case acc[key] do
        value when is_binary(value) -> Map.put(acc, key, bare_id(value))
        _absent -> acc
      end
    end)
  end

  defp bare_id(value) do
    case String.split(value, "-", parts: 2) do
      [prefix, rest] when prefix in @entry_prefixes -> bare_id(rest)
      _plain_uuid -> value
    end
  end

  defp boundary_id(entry) do
    entry |> Presenter.status_from_entry() |> Map.fetch!(:id) |> bare_id()
  end

  # Who is reading, so the hearts and bookmarks in the answer are theirs: a
  # page identity engages as the page, a member as themselves.
  defp viewer(conn), do: conn.assigns.current_organization || conn.assigns.current_user

  @doc """
  The instance-wide public timeline.

  Built on `Posts.recent_public_posts(:all, …)`, which is the site feed the RSS
  aggregate already uses — and that matters: it lists only authors who opted out
  of **nothing**, neither of search engines nor of AI use. So this endpoint
  inherits vutuv's existing consent rule for aggregate surfaces rather than
  inventing a firehose the website does not offer.
  """
  def public(conn, params) do
    page = Pagination.params(params)

    statuses =
      :all
      |> Posts.recent_public_posts(Pagination.opts(page))
      |> Presenter.statuses(viewer(conn))

    conn
    |> Pagination.link_header(Enum.map(statuses, &bare_id(&1.id)), page)
    |> json(statuses)
  end

  @doc """
  A hashtag's timeline, the same one `/tags/:slug` renders — including the posts
  from other networks it collects, since that is what makes a topic worth
  following from a phone at all.
  """
  def tag(conn, %{"hashtag" => slug} = params) do
    page = Pagination.params(strip_prefixes(params))

    statuses =
      case Tags.get_canonical_tag_by_slug(String.downcase(slug)) do
        %Tag{} = tag ->
          tag
          |> Timeline.walk(Pagination.opts(page))
          |> Presenter.statuses(viewer(conn))

        nil ->
          []
      end

    conn
    |> Pagination.link_header(Enum.map(statuses, &bare_id(&1.id)), page)
    |> json(statuses)
  end

  # The merged cursor is second-precision and cannot separate entries written in
  # the same second, so it only narrows the fetch to the boundary second;
  # `Pagination.window/3` does the cutting on the ids, which are unique and
  # ordered by creation. See `Pagination.fetch_size/1` for the headroom.
  defp load(conn, page) do
    opts = [limit: Pagination.fetch_size(page), cursor: cursor(page)]

    entries =
      case conn.assigns.current_organization do
        nil ->
          Posts.feed_page(conn.assigns.current_user, opts).entries

        organization ->
          organization
          |> Posts.organization_feed_page(Keyword.put(opts, :viewer, conn.assigns.current_user))
          |> Map.fetch!(:entries)
      end

    Pagination.window(entries, page, &boundary_id/1)
  end

  # `since_id`/`min_id` have no cursor equivalent in the merged paginator, which
  # only ever walks backwards. Answering the newest page for them is what a
  # client expects from `since_id` anyway, and is the honest answer for `min_id`
  # rather than a silently wrong window.
  defp cursor(%Pagination{max_id: nil}), do: nil

  defp cursor(%Pagination{max_id: max_id}) do
    case UUIDv7.timestamp(max_id) do
      nil -> nil
      at -> %{at: at, ids: Enum.map(@entry_prefixes, &"#{&1}-#{max_id}")}
    end
  end
end
