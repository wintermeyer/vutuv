defmodule Vutuv.Tags.LinkableCacheTest do
  @moduledoc """
  `Vutuv.Tags.linkable_slugs/1` answers "which of these written `#hashtags`
  should become links" and used to ask the database **once per rendered post
  body** — which on a feed page is once per card. The cache in front of it turns
  the repeat asks into ETS reads.

  The cache process is off in the test env (`:linkable_tag_cache`), so every
  other test keeps seeing the live query; these tests start their own isolated
  instance and hand its table in.

  **`async: false`, and it has to be**: what these tests assert is a *query
  count*, and `:telemetry.attach/4` is global — an async module would count
  every query the twenty cases running beside it happened to make, so the
  counts would drift with the seed. The ETS table is per-test; the handler is
  not.
  """
  use Vutuv.DataCase, async: false
  import Vutuv.PostsHelpers

  alias Vutuv.Tags
  alias Vutuv.Tags.LinkableCache
  alias Vutuv.Tags.Tag

  setup do
    # Its own table and name, so nothing here leaks into another test's answers.
    # Its own child id too, so a test that also wants the real-named instance
    # (the page-prefetch one below) is not rejected as a duplicate child.
    table = :"linkable_cache_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec({LinkableCache, name: table, table: table}, id: table)
    )

    %{table: table}
  end

  # Counts the SQL a block runs, which is the whole point of the cache.
  defp count_queries(fun) do
    ref = make_ref()
    parent = self()
    handler = "qc-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:vutuv, :repo, :query],
      fn _e, _m, _md, _c -> send(parent, {ref, :query}) end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, 0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(ref, n) do
    receive do
      {^ref, :query} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end

  # A tag worth a click: a real tag one visible member carries, which is the
  # `held` arm of the union `linkable_slugs/2` asks.
  defp linkable_tag(base), do: linkable_tag_named(unique_tag_name(base))

  defp linkable_tag_named(name) do
    tag = insert(:tag, name: name, slug: Vutuv.SlugHelpers.gen_tag_slug_unique(name, Tag, :slug))
    insert(:user_tag, user: insert(:activated_user), tag: tag)
    tag
  end

  describe "the second ask costs no query" do
    test "a known tag is answered from the table", %{table: table} do
      tag = linkable_tag("Elixir")
      written = String.downcase(tag.name)

      {first, first_queries} = count_queries(fn -> Tags.linkable_slugs([written], table) end)
      {second, second_queries} = count_queries(fn -> Tags.linkable_slugs([written], table) end)

      assert first == %{written => tag.slug}
      assert second == first, "a cached answer must equal the live one"
      assert first_queries > 0, "the first ask has to reach the database"
      assert second_queries == 0, "the second ask must not"
    end

    test "an unknown hashtag is remembered as unknown", %{table: table} do
      # Negative caching is the half that matters most: almost every hashtag on
      # a cached remote post names no topic here, so without it the feed's
      # repeat renders would re-ask for every one of them.
      written = "nichtvorhanden#{System.unique_integer([:positive])}"

      {first, first_queries} = count_queries(fn -> Tags.linkable_slugs([written], table) end)
      {second, second_queries} = count_queries(fn -> Tags.linkable_slugs([written], table) end)

      assert first == %{}
      assert second == %{}
      assert first_queries > 0
      assert second_queries == 0
    end

    test "a page's worth of bodies asks once, not once per body", %{table: table} do
      tag = linkable_tag("Fotografie")
      written = String.downcase(tag.name)

      # What a feed page does today: twenty cards, each rendering its own body.
      {_, queries} =
        count_queries(fn ->
          for _ <- 1..20, do: Tags.linkable_slugs([written], table)
        end)

      assert queries == 1, "twenty bodies naming one tag must cost one query, got #{queries}"
    end
  end

  describe "the cache never changes the answer" do
    test "mixed known and unknown names resolve exactly as the live query does", %{table: table} do
      tag = linkable_tag("Thüringen")
      written = String.downcase(tag.name)
      stranger = "keintag#{System.unique_integer([:positive])}"

      live = Tags.linkable_slugs([written, stranger])
      cached_cold = Tags.linkable_slugs([written, stranger], table)
      cached_warm = Tags.linkable_slugs([written, stranger], table)

      assert cached_cold == live
      assert cached_warm == live
      assert Map.has_key?(live, written), "the transliterated German tag must still link"
      refute Map.has_key?(live, stranger)
    end

    test "a hashtag that names nothing foldable stays plain text", %{table: table} do
      # `MatchKey.normalize/1` answers nil for these, so they never reach the
      # query and must never reach the cache either.
      assert Tags.linkable_slugs(["-", "."], table) == %{}
      assert Tags.linkable_slugs(["-", "."], table) == %{}
    end

    test "an empty list still skips the database", %{table: table} do
      {result, queries} = count_queries(fn -> Tags.linkable_slugs([], table) end)
      assert result == %{}
      assert queries == 0
    end
  end

  describe "staleness is bounded" do
    test "an expired entry is asked again", %{table: table} do
      written = "spaeter#{System.unique_integer([:positive])}"

      # Ask once with a TTL that is already spent by the time we ask again.
      Tags.linkable_slugs([written], table)
      LinkableCache.expire_all(table)

      {_, queries} = count_queries(fn -> Tags.linkable_slugs([written], table) end)
      assert queries > 0, "an expired entry must not be served"
    end

    test "a tag created after the answer was cached links once the entry expires", %{table: table} do
      name = "Nachzuegler#{System.unique_integer([:positive])}"
      written = String.downcase(name)

      assert Tags.linkable_slugs([written], table) == %{}

      tag = linkable_tag_named(name)
      assert Tags.linkable_slugs([written], table) == %{}, "still the cached answer"

      LinkableCache.expire_all(table)
      assert Tags.linkable_slugs([written], table) == %{written => tag.slug}
    end
  end

  describe "a feed page warms the whole page at once" do
    test "after building a page, every card's own hashtag lookup is free" do
      # The memo alone only helps the SECOND render of a body. The prefetch in
      # `decorate_feed_entries/3` is what makes the first one cheap too: it is
      # the only place that can see the whole page, so it asks once for all of
      # it and every card then reads the answer out of the table.
      #
      # This one runs the cache under its real name — the app-wide process is
      # off in this env, and the module is sync, so nothing else can see it.
      start_supervised!(LinkableCache)

      author = insert(:activated_user)
      reader = insert(:activated_user)
      follow!(reader, author)

      names = for i <- 1..6, do: unique_tag_name("Thema#{i}")
      for name <- names, do: linkable_tag_named(name)

      for name <- names, do: create_post!(author, %{body: "Etwas über ##{name}."})

      page = Vutuv.Posts.feed_page(reader, limit: 20)
      assert length(page.entries) == 6

      # What each card does while rendering its body.
      {_, queries} =
        count_queries(fn ->
          for entry <- page.entries do
            entry.post
            |> Vutuv.Posts.text()
            |> Vutuv.Mentions.written_hashtags()
            |> Tags.linkable_slugs()
          end
        end)

      assert queries == 0,
             "the page's prefetch must have answered every card already, got #{queries} queries"
    end
  end

  describe "the cache is never a requirement" do
    test "a missing table falls through to the live query" do
      # The process is off in this env, so the app-wide table does not exist —
      # the same shape as the moment before boot finishes.
      tag = linkable_tag("Ausfall")
      written = String.downcase(tag.name)

      assert Tags.linkable_slugs([written], :no_such_linkable_table) == %{written => tag.slug}
    end
  end
end
