defmodule Vutuv.Tags.Timeline do
  @moduledoc """
  What a tag page shows below its front matter: everything written about a topic,
  from **both** worlds, in one list a reader can sort, narrow and search.

  Two sources, merged in SQL rather than stitched together afterwards, because
  the reader is asking one question ("what about berlin?") and any merge done in
  Elixir would have to fetch far more than a page from each side to be sure of
  the order:

    * vutuv posts carrying the tag (`Vutuv.Posts.tag_posts_query/1` — the
      composer's tag field *and* a `#hashtag` in the body, unioned there), in
      the anonymous public view every visitor may read;
    * posts cached from other networks whose hashtags name the tag
      (`Vutuv.Fediverse.RemotePostTag`), **public audience only** — see
      `remote_posts_query/1`.

  ## What a caller gets

  `page/2` returns `%{entries:, total:, more?:}`. An entry is one of

      %{id: "post-<uuid>",   at: ~N[…], post: %Vutuv.Posts.Post{}}
      %{id: "remote-<uuid>", at: ~N[…], remote_post: %Vutuv.Fediverse.RemotePost{}}

  which is the shape the feed's renderer and `VutuvWeb.AgentDocs.PostDoc`
  already understand, so the HTML page and the `.md`/`.txt`/`.json`/`.xml`
  siblings read the same list.

  ## The controls

  `:source` — `:all`, `:vutuv` or `:fediverse`. The tabs **partition** the list:
  every entry is exactly one of the two, so the pair is "all".

  `:sort` — `:newest` (the default), `:oldest` or `:likes`. Both kinds bring a
  real tally to that order now (issue #1283): a member's post its hearts plus
  the favourites that arrived over ActivityPub, a cached remote post the figure
  its **own origin** publishes in the object's `likes` collection. Until that
  figure existed the remote half had to be counted as zero and settled at the
  bottom, and the page carried a line apologising for it. What is left of that
  caveat is the handful of servers that serve no such collection: a null cannot
  be ranked, so those posts still sort as zero — indistinguishable, here, from a
  post nobody liked.

  `:query` — full text, over `posts.search_tsv` and `fediverse_posts.search_tsv`,
  so both sides answer the same question the same way (a substring match on one
  side and a word match on the other would be one list with two search
  behaviours).

  `:from` / `:until` — `Date`s, read as **German calendar days**
  (`Vutuv.BerlinTime.day_bounds_utc/1`), inclusive at both ends. A reader
  filtering "since 1 July" means the day, not an instant in UTC.

  Offset-paginated (`:page`, `:per_page`) rather than cursor-paginated, because
  the sort is the reader's to change: a cursor encodes a position in one order
  and would be meaningless the moment they pick another.
  """

  import Ecto.Query

  alias Vutuv.BerlinTime
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Fediverse.RemotePostTag
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.Tags.Tag

  @per_page 20

  @sources ~w(all vutuv fediverse)a
  @sorts ~w(newest oldest likes)a

  @doc "Entries per page of the tag timeline."
  def per_page, do: @per_page

  @doc "The source tabs, as atoms (`:all` is the default)."
  def sources, do: @sources

  @doc "The sort orders, as atoms (`:newest` is the default)."
  def sorts, do: @sorts

  @doc """
  Maps a raw control value (a `phx-value`, a query param) to a source, falling
  back to `:all` for anything unrecognised — the same forgiving shape
  `Vutuv.Posts.normalize_feed_filter/1` has, so a stale link or a typed URL
  lands on the full list instead of an error.
  """
  def normalize_source(value), do: normalize(value, @sources, :all)

  @doc "The sort twin of `normalize_source/1`, falling back to `:newest`."
  def normalize_sort(value), do: normalize(value, @sorts, :newest)

  defp normalize(value, allowed, default) when is_binary(value) do
    Enum.find(allowed, default, &(Atom.to_string(&1) == value))
  end

  defp normalize(value, allowed, default) when is_atom(value) do
    if value in allowed, do: value, else: default
  end

  defp normalize(_value, _allowed, default), do: default

  @doc """
  Reads a `"YYYY-MM-DD"` date filter (what a native date input posts), returning
  `nil` for a blank or unparseable value so a half-typed date narrows nothing
  rather than emptying the page.
  """
  def normalize_date(%Date{} = date), do: date

  def normalize_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  def normalize_date(_value), do: nil

  @doc """
  Trims a search box's value, mapping blank to `nil` so "no query" is one thing
  and not three.
  """
  def normalize_query(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_query(_value), do: nil

  @doc """
  One page of the timeline, plus the total behind it and whether more follows.

  Options: `:source`, `:sort`, `:query`, `:from`, `:until`, `:page`,
  `:per_page` — every one already normalized by the functions above (the
  LiveView and the controller both do that at their edge, so this never guesses
  at a raw param).
  """
  def page(%Tag{} = tag, opts \\ []) do
    filters = filters(opts)
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, @per_page)

    rows =
      tag
      |> keys(filters)
      # One row more than a page, so `more?` costs no second query.
      |> limit(^(per_page + 1))
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    {rows, more?} = split_overflow(rows, per_page)

    %{entries: load(rows), total: total(tag, filters), more?: more?}
  end

  @doc """
  How many entries the timeline holds under `opts` — the figure the page prints
  beside the controls ("42 Beiträge"), read on its own so a caller that only
  wants the number does not fetch a page of rows.
  """
  def count(%Tag{} = tag, opts \\ []), do: total(tag, filters(opts))

  defp filters(opts) do
    %{
      source: Keyword.get(opts, :source, :all),
      sort: Keyword.get(opts, :sort, :newest),
      query: Keyword.get(opts, :query),
      from: Keyword.get(opts, :from),
      until: Keyword.get(opts, :until)
    }
  end

  defp total(tag, filters) do
    Repo.one(from(row in subquery(combined(tag, filters)), select: count()))
  end

  # One page of `{kind, id}` keys, ordered. The rows are fetched as keys and the
  # records loaded per kind afterwards: a union can only carry columns both
  # sides have, and a post and a cached remote post have almost nothing in
  # common beyond an id and a timestamp.
  defp keys(tag, filters) do
    from(row in subquery(combined(tag, filters)),
      select: %{kind: row.kind, id: row.id, at: row.at}
    )
    |> order_entries(filters.sort)
  end

  defp order_entries(query, :oldest), do: order_by(query, [row], asc: row.at, asc: row.id)

  # Likes first, then newest — so posts that share a tally (and the handful
  # whose origin serves none, which sort as zero) are at least in a sensible
  # order among themselves rather than in whatever order the planner returns
  # them.
  defp order_entries(query, :likes),
    do: order_by(query, [row], desc: row.likes, desc: row.at, desc: row.id)

  defp order_entries(query, _newest), do: order_by(query, [row], desc: row.at, desc: row.id)

  defp combined(tag, %{source: :vutuv} = filters), do: posts_query(tag, filters)
  defp combined(tag, %{source: :fediverse} = filters), do: remote_query(tag, filters)

  defp combined(tag, filters) do
    union_all(posts_query(tag, filters), ^remote_query(tag, filters))
  end

  # `kind` and `likes` are literals rather than columns, so both arms of the
  # union line up; `at` is a `timestamp` on both sides (Ecto's `:utc_datetime`
  # and `:naive_datetime` are the same Postgres type), which is what lets one
  # ORDER BY interleave them.
  defp posts_query(tag, filters) do
    tag
    |> Posts.tag_posts_query()
    |> search_posts(filters.query)
    |> between(filters, dynamic([p], p.inserted_at))
    |> select([p], %{
      kind: "post",
      id: p.id,
      at: p.inserted_at,
      likes:
        fragment(
          """
          (SELECT count(*) FROM post_likes l WHERE l.post_id = ?)
          + (SELECT count(*) FROM fediverse_reactions fr
              WHERE fr.post_id = ? AND fr.kind = 'like')
          """,
          p.id,
          p.id
        )
    })
  end

  defp remote_query(tag, filters) do
    tag
    |> remote_posts_query()
    |> search_remote(filters.query)
    |> between(filters, dynamic([rp], rp.published_at))
    |> select([rp], %{
      kind: "remote",
      id: rp.id,
      # Read back as a naive stamp, the type the vutuv arm's `inserted_at` has:
      # in Postgres both columns are a plain `timestamp`, so the union is
      # already legal, and matching the Elixir type keeps the two entry kinds
      # comparable in the renderer.
      at: type(rp.published_at, :naive_datetime),
      # The origin's own tally (issue #1283), not a count of what happened to
      # pass through this installation — which is why these posts can share one
      # order with vutuv's own instead of being parked at the bottom. A server
      # that serves no `likes` collection leaves it null, and a null cannot be
      # ranked, so it sorts as the zero it is indistinguishable from here.
      likes: fragment("coalesce(?, 0)::bigint", rp.likes_count)
    })
  end

  @doc """
  The cached remote posts filed under `tag` that a tag page may show — the one
  place that decides it.

  **Public audience only.** `unlisted` is not a smaller kind of public: it means
  the author asked their own server to keep the post off its discovery surfaces,
  and a topic page that search engines read is exactly such a surface. A
  followers-only post is not ours to publish at all. The feed can be laxer
  because it answers to one reader's own follow; this page answers to everybody,
  including a crawler.

  Expired copies are excluded rather than trusted to the sweeper: the retention
  ceiling is the legal footing for holding somebody else's post at all, so a row
  the sweeper has not reached yet must not still be published.

  An installation with the fediverse switched off has no remote half at all.
  """
  def remote_posts_query(%Tag{} = tag) do
    if Fediverse.enabled?() do
      from(rp in RemotePost,
        join: pt in RemotePostTag,
        on: pt.remote_post_id == rp.id,
        where: pt.tag_id == ^tag.id,
        where: rp.audience == "public",
        where: rp.expires_at > ^DateTime.utc_now(:second)
      )
    else
      from(rp in RemotePost, where: false)
    end
  end

  defp search_posts(query, nil), do: query

  defp search_posts(query, text) do
    where(query, [p], fragment("? @@ websearch_to_tsquery('simple', ?)", p.search_tsv, ^text))
  end

  defp search_remote(query, nil), do: query

  defp search_remote(query, text) do
    where(query, [rp], fragment("? @@ websearch_to_tsquery('simple', ?)", rp.search_tsv, ^text))
  end

  # The date range as German calendar days, half-open at the top end
  # (`day_bounds_utc/1` gives `[start, finish)`), so "until 31 July" includes
  # everything written on the 31st.
  defp between(query, %{from: nil, until: nil}, _at), do: query

  defp between(query, %{from: from, until: until}, at) do
    query
    |> filter_from(from, at)
    |> filter_until(until, at)
  end

  defp filter_from(query, nil, _at), do: query

  defp filter_from(query, %Date{} = date, at) do
    {start, _finish} = BerlinTime.day_bounds_utc(date)
    where(query, ^dynamic(^at >= ^start))
  end

  defp filter_until(query, nil, _at), do: query

  defp filter_until(query, %Date{} = date, at) do
    {_start, finish} = BerlinTime.day_bounds_utc(date)
    where(query, ^dynamic(^at < ^finish))
  end

  # The extra row `page/2` fetched: whether it came back is the answer to "is
  # there more", and it never reaches the caller.
  defp split_overflow(rows, per_page) do
    case Enum.split(rows, per_page) do
      {page, []} -> {page, false}
      {page, _overflow} -> {page, true}
    end
  end

  # The keys, back as renderable records, in the order the union put them.
  defp load([]), do: []

  defp load(rows) do
    posts = load_posts(for %{kind: "post", id: id} <- rows, do: id)
    remotes = load_remote(for %{kind: "remote", id: id} <- rows, do: id)

    for row <- rows, record = Map.get(if(row.kind == "post", do: posts, else: remotes), row.id) do
      entry(row, record)
    end
  end

  defp entry(%{kind: "post", at: at} = row, post),
    do: %{id: "post-" <> row.id, at: at, post: post}

  defp entry(%{at: at} = row, remote_post),
    do: %{id: "remote-" <> row.id, at: at, remote_post: remote_post}

  defp load_posts([]), do: %{}

  defp load_posts(ids) do
    from(p in Vutuv.Posts.Post, where: p.id in ^ids)
    |> Repo.all()
    |> Repo.preload(Posts.render_preloads())
    |> Map.new(&{&1.id, &1})
  end

  defp load_remote([]), do: %{}

  defp load_remote(ids) do
    from(rp in RemotePost,
      where: rp.id in ^ids,
      preload: [:screenshot, remote_account: ^from(a in RemoteAccount)]
    )
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end
end
