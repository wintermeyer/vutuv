defmodule Vutuv.Tags.TimelineTest do
  @moduledoc """
  The tag page's merged timeline (`Vutuv.Tags.Timeline`): vutuv posts and cached
  posts from other networks in one list, with the reader's source tabs, sort,
  search and date range.

  The anonymous public view throughout — a tag page is served to everybody,
  including a crawler — which is why the visibility cases ported from the old
  "Posts with this tag" list live here now.
  """
  use Vutuv.DataCase, async: true
  import Vutuv.PostsHelpers

  alias Vutuv.Fediverse.Hashtags
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.Timeline

  # Per-module unique tag names so async files never share a tags.slug lock
  # (see the test guidelines in .claude/rules/elixir.md).
  tl_mod_id = :erlang.phash2(__MODULE__, 4_294_967_296)
  @elixir_tag "elixir-#{tl_mod_id}"
  @ruby_tag "ruby-#{tl_mod_id}"

  defp author(attrs \\ []), do: insert(:activated_user, attrs)

  # The module's own tag, whether a post in this test already minted it or not.
  defp elixir_tag do
    Repo.get_by(Tag, name: @elixir_tag) ||
      insert(:tag, name: @elixir_tag, slug: Vutuv.SlugHelpers.tagify(@elixir_tag))
  end

  defp ids(%{entries: entries}), do: Enum.map(entries, & &1.id)

  # Backdates a post, since several posts made inside one test share a
  # second-truncated `inserted_at` and the timeline sorts on it.
  defp at(post, ago_seconds) do
    stamp = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -ago_seconds)
    Repo.update_all(from(p in Posts.Post, where: p.id == ^post.id), set: [inserted_at: stamp])
    post
  end

  defp remote_account do
    Repo.insert!(%RemoteAccount{
      actor_uri: "https://social.example/users/them-#{System.unique_integer([:positive])}",
      host: "social.example",
      handle: "them",
      name: "Them Themself",
      inbox_uri: "https://social.example/inbox"
    })
  end

  # A cached remote post filed under `tag`, `ago_seconds` old. Filed through the
  # ActivityPub tag array rather than a `#hashtag` in the text, because this
  # module's tag names carry a hyphen (async isolation) and the hashtag grammar
  # ends a tag at one.
  defp remote_post(tag, text, ago_seconds \\ 0, overrides \\ %{}) do
    now = DateTime.utc_now(:second)

    post =
      Repo.insert!(
        struct(
          %RemotePost{
            remote_account_id: remote_account().id,
            object_uri: "https://social.example/posts/#{System.unique_integer([:positive])}",
            origin_url: "https://social.example/@them/1",
            content_text: text,
            audience: "public",
            kind: "note",
            published_at: DateTime.add(now, -ago_seconds),
            received_at: now,
            expires_at: DateTime.add(now, 86_400)
          },
          overrides
        )
      )

    Hashtags.sync(post, %{"tag" => [%{"type" => "Hashtag", "name" => "#" <> tag.name}]})
    post
  end

  describe "the vutuv half" do
    test "lists public posts carrying the tag, newest first" do
      a = author()
      older = a |> create_post!(%{body: "First", tags: @elixir_tag}) |> at(60)
      newer = a |> create_post!(%{body: "Second", tags: @elixir_tag}) |> at(30)
      _other = create_post!(a, %{body: "Ruby", tags: @ruby_tag})

      page = Timeline.page(elixir_tag())

      assert ids(page) == ["post-" <> newer.id, "post-" <> older.id]
      assert page.total == 2
      refute page.more?
    end

    test "the post is preloaded for rendering" do
      a = author()
      create_post!(a, %{body: "Hello", tags: @elixir_tag})

      assert %{entries: [%{post: post}]} = Timeline.page(elixir_tag())
      assert post.user.id == a.id
      assert Enum.map(post.tags, & &1.name) == [@elixir_tag]
    end

    test "hides denied, frozen and unconfirmed-author posts" do
      a = author()

      create_post!(a, %{
        body: "followers only",
        tags: @elixir_tag,
        denials: [%{"wildcard" => "non_followers"}]
      })

      frozen = create_post!(a, %{body: "frozen", tags: @elixir_tag})

      Repo.update_all(from(p in Posts.Post, where: p.id == ^frozen.id),
        set: [frozen_at: NaiveDateTime.utc_now(:second)]
      )

      unconfirmed = insert(:user, email_confirmed?: false)
      create_post!(unconfirmed, %{body: "spam", tags: @elixir_tag})

      assert %{entries: [], total: 0} = Timeline.page(elixir_tag())
    end

    test "a post reaching the tag through a body hashtag is listed once" do
      a = author()
      tag = insert(:tag, name: "berlin_#{System.unique_integer([:positive])}")
      tag = Repo.update!(Ecto.Changeset.change(tag, slug: Vutuv.SlugHelpers.tagify(tag.name)))

      # Both filings at once: the composer's field and the body's hashtag. One
      # entry, or the tag page would print the post twice.
      hashtag_only = create_post!(a, %{body: "Grüße aus ##{tag.slug}"})
      both = create_post!(a, %{body: "Wieder in ##{tag.slug}", tags: tag.name})

      page = Timeline.page(tag)

      assert page.total == 2
      assert Enum.sort(ids(page)) == Enum.sort(["post-" <> hashtag_only.id, "post-" <> both.id])
    end

    test "offset-pages and reports whether more follows" do
      a = author()

      posts =
        for i <- 1..5, do: at(create_post!(a, %{body: "post #{i}", tags: @elixir_tag}), 60 - i)

      [_p1, p2, p3, p4, p5] = posts
      tag = elixir_tag()

      page1 = Timeline.page(tag, page: 1, per_page: 2)
      page2 = Timeline.page(tag, page: 2, per_page: 2)
      page3 = Timeline.page(tag, page: 3, per_page: 2)

      assert ids(page1) == ["post-" <> p5.id, "post-" <> p4.id]
      assert page1.more?
      assert ids(page2) == ["post-" <> p3.id, "post-" <> p2.id]
      assert length(page3.entries) == 1
      refute page3.more?
      assert page3.total == 5
    end

    test "an empty tag is an empty page" do
      assert %{entries: [], total: 0, more?: false} = Timeline.page(insert(:tag))
    end
  end

  describe "the fediverse half" do
    test "a cached public post filed under the tag joins the list, in time order" do
      a = author()
      mine = a |> create_post!(%{body: "Mine", tags: @elixir_tag}) |> at(60)
      tag = elixir_tag()
      theirs = remote_post(tag, "Theirs", 30)

      page = Timeline.page(tag)

      assert ids(page) == ["remote-" <> theirs.id, "post-" <> mine.id]
      assert page.total == 2
    end

    test "the remote post is preloaded with its account" do
      tag = elixir_tag()
      remote_post(tag, "Theirs")

      assert %{entries: [%{remote_post: post}]} = Timeline.page(tag)
      assert post.remote_account.handle == "them"
    end

    test "an unlisted, followers-only or expired copy is never published here" do
      tag = elixir_tag()
      remote_post(tag, "Unlisted", 0, %{audience: "unlisted"})
      remote_post(tag, "Followers", 0, %{audience: "followers"})

      remote_post(tag, "Expired", 0, %{
        expires_at: DateTime.add(DateTime.utc_now(:second), -60)
      })

      assert %{entries: [], total: 0} = Timeline.page(tag)
    end
  end

  describe "the source tabs" do
    setup do
      a = author()
      tag = elixir_tag()
      mine = a |> create_post!(%{body: "Mine", tags: @elixir_tag}) |> at(60)
      theirs = remote_post(tag, "Theirs", 30)

      %{tag: tag, mine: mine, theirs: theirs}
    end

    test "partition the list", %{tag: tag, mine: mine, theirs: theirs} do
      assert ids(Timeline.page(tag, source: :vutuv)) == ["post-" <> mine.id]
      assert ids(Timeline.page(tag, source: :fediverse)) == ["remote-" <> theirs.id]
      assert length(Timeline.page(tag, source: :all).entries) == 2
    end

    test "carry their own total", %{tag: tag} do
      assert Timeline.page(tag, source: :vutuv).total == 1
      assert Timeline.page(tag, source: :fediverse).total == 1
    end
  end

  describe "sorting" do
    test "oldest first reverses the default" do
      a = author()
      tag = elixir_tag()
      older = a |> create_post!(%{body: "First", tags: @elixir_tag}) |> at(60)
      newer = a |> create_post!(%{body: "Second", tags: @elixir_tag}) |> at(30)

      assert ids(Timeline.page(tag, sort: :oldest)) == ["post-" <> older.id, "post-" <> newer.id]
    end

    test "most liked outranks recency, and the countless remote post lands last" do
      a = author()
      tag = elixir_tag()

      # Oldest first in this list, newest last, so nothing but the like count
      # can produce the expected order.
      popular = a |> create_post!(%{body: "Popular", tags: @elixir_tag}) |> at(60)
      quiet = a |> create_post!(%{body: "Quiet", tags: @elixir_tag}) |> at(30)
      # A cached remote post carries no public tally, so it counts as zero
      # however new it is.
      theirs = remote_post(tag, "Theirs", 0)

      :ok = Posts.like_post(author(), popular)
      :ok = Posts.like_post(author(), popular)
      :ok = Posts.like_post(author(), quiet)

      assert ids(Timeline.page(tag, sort: :likes)) == [
               "post-" <> popular.id,
               "post-" <> quiet.id,
               "remote-" <> theirs.id
             ]
    end
  end

  describe "search" do
    test "asks both sources the same question" do
      a = author()
      tag = elixir_tag()
      match = a |> create_post!(%{body: "Vom Hafen in Hamburg", tags: @elixir_tag}) |> at(60)
      _miss = a |> create_post!(%{body: "Etwas ganz anderes", tags: @elixir_tag}) |> at(50)
      theirs = remote_post(tag, "Auch etwas über Hamburg", 30)

      page = Timeline.page(tag, query: "Hamburg")

      assert Enum.sort(ids(page)) ==
               Enum.sort(["post-" <> match.id, "remote-" <> theirs.id])

      assert page.total == 2
    end

    test "a blank query narrows nothing" do
      a = author()
      create_post!(a, %{body: "Anything", tags: @elixir_tag})

      assert Timeline.page(elixir_tag(), query: Timeline.normalize_query("  ")).total ==
               1
    end
  end

  describe "the date range" do
    test "keeps both end days, read as German calendar days" do
      a = author()
      tag = elixir_tag()
      today = Vutuv.BerlinTime.today()

      old = a |> create_post!(%{body: "Long ago", tags: @elixir_tag}) |> at(10 * 86_400)
      recent = create_post!(a, %{body: "Today", tags: @elixir_tag})

      from_today = Timeline.page(tag, from: today)
      assert ids(from_today) == ["post-" <> recent.id]

      until_yesterday = Timeline.page(tag, until: Date.add(today, -1))
      assert ids(until_yesterday) == ["post-" <> old.id]

      # The end day itself is inside the range, not before it.
      assert ids(Timeline.page(tag, from: today, until: today)) == ["post-" <> recent.id]
    end
  end

  describe "normalizing the controls" do
    test "falls back rather than failing on an unknown value" do
      assert Timeline.normalize_source("fediverse") == :fediverse
      assert Timeline.normalize_source("nonsense") == :all
      assert Timeline.normalize_source(nil) == :all
      assert Timeline.normalize_sort("likes") == :likes
      assert Timeline.normalize_sort("nonsense") == :newest
      assert Timeline.normalize_date("2026-07-31") == ~D[2026-07-31]
      assert Timeline.normalize_date("31.07.2026") == nil
      assert Timeline.normalize_date("") == nil
      assert Timeline.normalize_query("") == nil
      assert Timeline.normalize_query(" berlin ") == "berlin"
    end
  end
end
