defmodule Vutuv.Tags.ExternalPostsTest do
  @moduledoc """
  The scheduler behind the posts a followed tag pulls from the servers it names
  (issue #2126): which pairs are due, what the clock does on every outcome, and
  the two caps on the table.

  `async: false`, and deliberately so: the module flips
  `:fetch_external_tag_posts` (read by `Vutuv.Tags.ExternalPosts.enabled?/0` and
  by the supervision tree), `:external_tag_req_options` (the Req seam) and the
  two cap/budget keys. `Application.put_env/3` is global and the SQL sandbox
  does not roll it back.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.ExternalTagHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.NoteEvent
  alias Vutuv.Repo
  alias Vutuv.Tags
  alias Vutuv.Tags.ExternalFetch
  alias Vutuv.Tags.ExternalPost
  alias Vutuv.Tags.ExternalPosts
  alias Vutuv.Tags.Merge
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.TagFollow

  @source "mastodon.example"
  @other_source "troet.example"

  setup do
    put_config(:fetch_external_tag_posts, true)
    :ok
  end

  # A tag somebody here follows, with `source` named as one of its servers.
  defp followed_tag(source \\ @source) do
    user = insert(:activated_user)
    tag = insert(:tag)
    {:ok, follow} = Tags.follow_tag(user, tag)
    {:ok, _source} = Tags.add_tag_follow_source(follow, source)
    tag
  end

  defp block_host(host) do
    admin = insert(:activated_user)
    {:ok, {blocked, _purged}} = Fediverse.block_instance(%{"host" => host}, admin)
    blocked
  end

  defp status(attrs \\ %{}), do: remote_status(@source, attrs)

  defp fetch_row(tag, source \\ @source),
    do: Repo.get_by(ExternalFetch, tag_id: tag.id, source: source)

  # Age a pair's schedule rather than sleeping until it comes due.
  defp overdue!(tag, at),
    do: tag |> fetch_row() |> Ecto.Changeset.change(next_fetch_at: at) |> Repo.update!()

  # The address of one original, and one stored copy of it. Both given
  # explicitly: the helper's default url is the same string for every fixture,
  # and a test about matching on that column must not be able to match by
  # accident.
  defp original(path), do: "https://#{@source}/@ada/#{path}"

  defp copy(tag, url, source),
    do: external_post(tag, url: url, source: source, author_host: @source)

  # The two keys asked directly, with no row in the table: the address plus the
  # author it claims, and the three hosts the authority test compares. Above the
  # describes they belong to, because a `defp` inside one compiles to module
  # scope anyway and only looks scoped.
  defp key(url, host \\ @source), do: ExternalPost.origin_key(%{url: url, author_host: host})

  defp row(attrs), do: Enum.into(attrs, %{source: @source, author_host: @source})

  describe "due_sources/1" do
    test "answers a wanted pair that has never been fetched" do
      tag = followed_tag()

      assert [%{tag_id: tag_id, source: @source}] = ExternalPosts.due_sources(10)
      assert tag_id == tag.id
    end

    test "never answers the local source" do
      user = insert(:activated_user)
      tag = insert(:tag)
      {:ok, _follow} = Tags.follow_tag(user, tag)

      assert ExternalPosts.due_sources(10) == []
    end

    test "answers one row per pair however many members follow it" do
      tag = followed_tag()
      other = insert(:activated_user)
      {:ok, follow} = Tags.follow_tag(other, tag)
      {:ok, _} = Tags.add_tag_follow_source(follow, @source)

      assert [%{source: @source, follow_count: 2}] = ExternalPosts.due_sources(10)
    end

    test "drops a pair that was fetched inside its interval and answers it again after" do
      tag = followed_tag()
      stub_tag_timeline([])
      ExternalPosts.fetch_due()

      assert ExternalPosts.due_sources(10) == []

      overdue!(tag, DateTime.add(DateTime.utc_now(:second), -1))

      assert [%{source: @source}] = ExternalPosts.due_sources(10)
    end

    test "serves the most overdue pair first, and a never-fetched pair before both" do
      now = DateTime.utc_now(:second)
      long = followed_tag()
      short = followed_tag()
      fresh = followed_tag()

      stub_tag_timeline([])
      ExternalPosts.fetch_due()

      overdue!(long, DateTime.add(now, -3600))
      overdue!(short, DateTime.add(now, -60))
      Repo.delete!(fetch_row(fresh))

      assert [first, second, third] = ExternalPosts.due_sources(10)
      assert first.tag_id == fresh.id
      assert second.tag_id == long.id
      assert third.tag_id == short.id
    end

    test "carries the pair's schedule, so working the list costs no further query" do
      tag = followed_tag()
      stub_tag_timeline([])
      ExternalPosts.fetch_due()
      overdue!(tag, DateTime.utc_now(:second))

      assert [%{interval_seconds: seconds, strikes: 0}] = ExternalPosts.due_sources(10)
      assert seconds == fetch_row(tag).interval_seconds
    end
  end

  describe "the clock" do
    test "an unworkable pair is stamped and leaves the due set after one pass" do
      _tag = followed_tag("blocked.example")
      block_host("blocked.example")
      stub_tag_timeline([])

      assert [%{source: "blocked.example"}] = ExternalPosts.due_sources(10)
      assert %{skipped: 1} = ExternalPosts.fetch_due()
      assert ExternalPosts.due_sources(10) == []
      refute_received {:req, _host, _path, _query, _headers}
    end

    test "a failing server is stamped too, and takes a strike" do
      tag = followed_tag()
      stub_tag_timeline_status(503)

      assert %{failed: 1} = ExternalPosts.fetch_due()
      assert ExternalPosts.due_sources(10) == []
      assert %ExternalFetch{strikes: 1, checked_at: %DateTime{}} = fetch_row(tag)
    end

    test "one pair blowing up neither stops the pass nor leaves anything unstamped" do
      # The amplifier under every other clock rule here. An unguarded raise
      # aborts the whole `Enum.map`, so *nothing* is stamped — not even the
      # healthy pair, which then keeps its nil schedule, sits at the front under
      # `asc_nulls_first` and is re-tried into the same raise on every run.
      # #1316's shape widened from one wedged pair to the entire fetcher.
      broken = followed_tag()
      healthy = followed_tag()
      test_pid = self()
      broken_path = "/api/v1/timelines/tag/#{Tag.hashtag_name(broken.name)}"

      put_config(:external_tag_req_options,
        plug: fn conn ->
          send(
            test_pid,
            {:req, conn.host, conn.request_path, conn.query_string, conn.req_headers}
          )

          if conn.request_path == broken_path do
            exit(:boom)
          else
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!([status()]))
          end
        end
      )

      assert %{failed: 1, stored: 1} = ExternalPosts.fetch_due()

      assert %ExternalFetch{checked_at: %DateTime{}, strikes: 1} = fetch_row(broken)
      assert %ExternalFetch{checked_at: %DateTime{}, strikes: 0} = fetch_row(healthy)
      assert ExternalPosts.due_sources(10) == []
    end

    test "a successful fetch clears the strikes" do
      tag = followed_tag()
      stub_tag_timeline([])
      ExternalPosts.fetch_due()
      fetch_row(tag) |> Ecto.Changeset.change(strikes: 3) |> Repo.update!()
      overdue!(tag, DateTime.add(DateTime.utc_now(:second), -1))

      stub_tag_timeline([status()])
      assert %{stored: 1} = ExternalPosts.fetch_due()
      assert %ExternalFetch{strikes: 0} = fetch_row(tag)
    end
  end

  describe "cadence" do
    test "stays put when about the target number of posts arrived" do
      assert ExternalPosts.next_interval(3600, ExternalPosts.cadence()[:target]) == 3600
    end

    test "stretches when nothing arrived and tightens when a lot did" do
      assert ExternalPosts.next_interval(1800, 0) > 1800
      assert ExternalPosts.next_interval(1800, 50) < 1800
    end

    test "never goes below ten minutes or above three hours" do
      cadence = ExternalPosts.cadence()
      assert cadence[:min_seconds] == 600
      assert cadence[:max_seconds] == 10_800

      assert ExternalPosts.next_interval(600, 500) == 600
      assert ExternalPosts.next_interval(10_800, 0) == 10_800
    end

    test "a fetch that brought nothing schedules the next one further out" do
      tag = followed_tag()
      stub_tag_timeline([])

      ExternalPosts.fetch_due()
      row = fetch_row(tag)

      assert row.interval_seconds > ExternalPosts.cadence()[:min_seconds]
      assert DateTime.diff(row.next_fetch_at, row.checked_at) == row.interval_seconds
    end
  end

  describe "the caps" do
    test "keeps only the newest posts of one tag" do
      tag = followed_tag()
      per_tag = ExternalPosts.caps()[:per_tag]

      # August, so every fixture is safely in the past: a status dated in the
      # future is dropped on arrival rather than allowed to pin itself to the
      # top of the tag forever.
      statuses =
        for n <- 1..(per_tag + 5) do
          status(%{
            "id" => "s#{n}",
            "created_at" => "2026-08-#{String.pad_leading("#{n}", 2, "0")}T10:00:00.000Z"
          })
        end

      stub_tag_timeline(statuses)
      ExternalPosts.fetch_due()

      kept = Repo.all(from(p in ExternalPost, where: p.tag_id == ^tag.id, select: p.remote_id))
      assert length(kept) == per_tag
      assert "s#{per_tag + 5}" in kept
      refute "s1" in kept
    end

    test "the hard ceiling drops the oldest rows across every tag" do
      put_config(:external_tag_post_caps, per_tag: 10, total: 3)
      followed_tag()

      statuses =
        for n <- 1..5 do
          status(%{"id" => "s#{n}", "created_at" => "2026-08-0#{n}T10:00:00.000Z"})
        end

      stub_tag_timeline(statuses)
      ExternalPosts.fetch_due()

      assert Repo.aggregate(ExternalPost, :count) == 3
      kept = Repo.all(from(p in ExternalPost, select: p.remote_id))
      assert "s5" in kept
      refute "s1" in kept
    end
  end

  describe "the budget per server" do
    test "spreads one busy server over several runs" do
      put_config(:external_tag_fetch_budget, batch: 20, per_host: 2)
      for _ <- 1..4, do: followed_tag()
      _elsewhere = followed_tag(@other_source)

      due = ExternalPosts.due_sources(10)

      assert length(due) == 3
      assert Enum.count(due, &(&1.source == @source)) == 2
      assert Enum.count(due, &(&1.source == @other_source)) == 1
    end

    test "lets a second server's pair in past a first server that fills the batch" do
      # What the over-fetch is actually for. With a plain `LIMIT 4` the first
      # server takes every candidate slot, the budget cuts it to 2, and the
      # other server's pair — sitting just past the cut — is never looked at.
      put_config(:external_tag_fetch_budget, batch: 4, per_host: 2)
      for _ <- 1..8, do: followed_tag()
      _elsewhere = followed_tag(@other_source)

      due = ExternalPosts.due_sources(4)

      assert Enum.count(due, &(&1.source == @source)) == 2
      assert Enum.count(due, &(&1.source == @other_source)) == 1
    end

    test "serves fewer than the batch when only one server has pairs, and that is right" do
      # The comment used to claim the over-fetch stops a busy server shrinking
      # the run. It does not, and must not: no amount of over-fetching invents
      # pairs on servers nobody follows, and the budget is there precisely to
      # stop one server being asked four times in one pass.
      put_config(:external_tag_fetch_budget, batch: 4, per_host: 2)
      for _ <- 1..8, do: followed_tag()

      assert length(ExternalPosts.due_sources(4)) == 2
    end
  end

  describe "a tag merge" do
    test "takes the pulled posts and the schedule with it" do
      alias_tag = followed_tag()
      canonical = insert(:tag)
      stub_tag_timeline([status()])
      ExternalPosts.fetch_due()

      assert %{moved: moved} = Merge.preview(alias_tag, canonical)
      assert moved["external_tag_posts"] == 1
      assert moved["external_tag_fetches"] == 1

      assert {:ok, _merge} = Merge.merge(alias_tag, canonical)

      assert Repo.one!(from(p in ExternalPost, select: p.tag_id)) == canonical.id
      assert Repo.one!(from(f in ExternalFetch, select: f.tag_id)) == canonical.id
    end
  end

  describe "pruning" do
    test "drops the posts and the schedule of a pair nobody wants any more" do
      tag = followed_tag()
      stub_tag_timeline([status()])
      ExternalPosts.fetch_due()
      assert Repo.aggregate(ExternalPost, :count) == 1

      follow = Repo.one!(from(f in TagFollow, where: f.tag_id == ^tag.id))
      assert Tags.remove_tag_follow_source(follow, @source) == 1

      assert %{fetches: 1, posts: 1} = ExternalPosts.prune()
      assert Repo.aggregate(ExternalPost, :count) == 0
      assert Repo.aggregate(ExternalFetch, :count) == 0
    end
  end

  describe "the outbound flag" do
    test "off means no request at all and nothing due" do
      put_config(:fetch_external_tag_posts, false)
      _tag = followed_tag()
      stub_tag_timeline([status()])

      refute ExternalPosts.enabled?()
      assert ExternalPosts.fetch_due() == %{stored: 0, skipped: 0, failed: 0, fetched: 0}
      refute_received {:req, _host, _path, _query, _headers}
      assert Repo.aggregate(ExternalPost, :count) == 0
    end
  end

  describe "what is stored" do
    test "plain text and a link to the original, never a picture" do
      tag = followed_tag()

      stub_tag_timeline([
        status(%{
          "content" => "<p>Guten <b>Morgen</b></p>",
          "url" => "https://#{@source}/@ada/99",
          "media_attachments" => [%{"type" => "image", "url" => "https://#{@source}/pic.jpg"}]
        })
      ])

      assert %{stored: 1} = ExternalPosts.fetch_due()

      post = Repo.one!(from(p in ExternalPost, where: p.tag_id == ^tag.id))
      assert post.text == "Guten Morgen"
      assert post.url == "https://#{@source}/@ada/99"
      assert post.source == @source
      assert post.language == "de"
      assert post.author_acct == "ada"
      refute post.text =~ "pic.jpg"
    end

    test "the same status twice is one row, and only the new ones count" do
      _tag = followed_tag()
      first = status(%{"id" => "s1"})
      stub_tag_timeline([first])
      assert %{stored: 1} = ExternalPosts.fetch_due()

      stub_tag_timeline([first, status(%{"id" => "s2"})])

      Repo.one!(ExternalFetch)
      |> Ecto.Changeset.change(next_fetch_at: DateTime.utc_now(:second))
      |> Repo.update!()

      assert %{stored: 1} = ExternalPosts.fetch_due()
      assert Repo.aggregate(ExternalPost, :count) == 2
    end
  end

  # What a member means by Report is "this post, off this site", and what
  # relates the copies is `Vutuv.Tags.ExternalPost.origin/1`. Measured on a copy
  # of production: the one post somebody really did report stood as **six** rows
  # of which two were marked (issue #2164).
  describe "a report" do
    setup do
      {:ok, reporter: insert(:activated_user)}
    end

    # The attack this change was reverted for, and the reason it is back with a
    # guard (`7cdfd4dc7`, reverted as `8b2c1a862`). Both halves of the key are
    # written by the polled server and a member may name any host as a tag
    # source, so one line of JSON claims the victim's permalink **and** the
    # victim's author host at once. The first version keyed the takedown on
    # exactly that pair, so reporting the planted card blanked every honest copy
    # of the post, the one from the author's own server included.
    test "a planted claim on somebody else's address and author takes only itself down", %{
      reporter: reporter
    } do
      tag = followed_tag()
      url = original("4740")

      home = copy(tag, url, @source)
      relayed = copy(tag, url, @other_source)

      planted =
        external_post(tag,
          url: url,
          source: "impostor.example",
          author_host: @source,
          author_acct: "ada@#{@source}"
        )

      assert {:ok, :this_copy} = ExternalPosts.report(planted.id, reporter)
      assert Repo.get!(ExternalPost, planted.id).reported_at

      for id <- [home.id, relayed.id] do
        row = Repo.get!(ExternalPost, id)
        refute row.reported_at, "a planted claim on this address blanked an honest copy of it"
        assert row.text == "Hello from over there"
      end
    end

    # The same forgery, played a move earlier: plant the tombstone before the
    # post has ever arrived and the ingest gate refuses it for as long as the
    # tombstone lives. That is a member keeping somebody else's post out of this
    # installation altogether, which is why the gate asks the same question the
    # takedown does.
    test "a planted tombstone cannot keep the honest post out", %{reporter: reporter} do
      tag = followed_tag()

      planted =
        external_post(tag,
          url: original("s1"),
          source: "impostor.example",
          author_host: @source,
          author_acct: "ada@#{@source}"
        )

      assert {:ok, :this_copy} = ExternalPosts.report(planted.id, reporter)

      # The author's own server answers the tag we asked it for.
      stub_tag_timeline([status(%{"id" => "s1", "url" => original("s1")})])
      assert %{stored: 1} = ExternalPosts.fetch_due()

      stored = Repo.get_by!(ExternalPost, source: @source, remote_id: "s1")
      refute stored.reported_at
      assert stored.text == "Hello from over there"
    end

    # What a server that is not the author's own may still take down: the rows
    # **it** filed. A tag page and a feed hold one row per (tag, server), so the
    # same relayed status under two followed tags is two cards, and the server's
    # own word covers both of them.
    test "a relayed copy takes that server's copies, and nobody else's", %{reporter: reporter} do
      one = followed_tag()
      two = followed_tag(@other_source)
      url = original("4750")

      clicked = copy(two, url, @other_source)
      same_server = copy(one, url, @other_source)
      home = copy(one, url, @source)
      third_server = copy(one, url, "hachyderm.example")

      assert {:ok, :this_copy} = ExternalPosts.report(clicked.id, reporter)

      assert Repo.get!(ExternalPost, same_server.id).reported_at,
             "the same server's copy under another tag kept standing"

      refute Repo.get!(ExternalPost, home.id).reported_at
      refute Repo.get!(ExternalPost, third_server.id).reported_at
    end

    test "takes every copy of the same original, across servers and across tags", %{
      reporter: reporter
    } do
      one = followed_tag()
      two = followed_tag(@other_source)
      url = original("4711")

      clicked = copy(one, url, @source)
      other_server = copy(one, url, @other_source)
      other_tag = copy(two, url, @source)
      untouched = copy(one, original("4712"), @source)

      assert {:ok, :every_copy} = ExternalPosts.report(clicked.id, reporter)

      for id <- [clicked.id, other_server.id, other_tag.id] do
        row = Repo.get!(ExternalPost, id)
        assert row.reported_at, "a copy of the reported original kept standing"
        assert row.text == ""
        refute row.author_acct
      end

      standing = Repo.get!(ExternalPost, untouched.id)
      refute standing.reported_at
      assert standing.text == "Hello from over there"
    end

    # One server claiming another's permalink must not take down honest copies
    # of somebody else's post — `ExternalPost.origin_key/1` says why the address
    # alone cannot be the key.
    test "a row claiming somebody else's address is not a copy of it", %{reporter: reporter} do
      tag = followed_tag()
      url = original("4720")

      honest = external_post(tag, url: url, source: @source, author_host: @source)

      planted =
        external_post(tag,
          url: url,
          source: @other_source,
          author_host: @other_source,
          author_acct: "impostor@#{@other_source}"
        )

      assert {:ok, :this_copy} = ExternalPosts.report(planted.id, reporter)

      standing = Repo.get!(ExternalPost, honest.id)
      refute standing.reported_at, "a report reached a post by another author at the same address"
      assert standing.text == "Hello from over there"

      # And the honest author's post is still the one thing anybody may read.
      assert Repo.all(from(p in ExternalPosts.showable_query(), select: p.id)) == [honest.id]
    end

    # A redirect wrapper is not a second original: Bridgy Fed serves one Bluesky
    # post as both `bsky.brid.gy/r/<address>` and `fed.brid.gy/r/<address>`, and
    # both stood here — same author, same second — with nothing relating them,
    # which is this issue's own defect surviving for bridged posts. The bridge
    # itself is the author's server here, and the wrapper is an address on it,
    # so its own copy is the one that speaks for the pair.
    test "a post behind two redirect wrappers is one original", %{reporter: reporter} do
      tag = followed_tag()
      bluesky = "https://bsky.app/profile/did:plc:abc/post/3mv2azzztuk2i"

      clicked =
        external_post(tag,
          url: "https://bsky.brid.gy/r/#{bluesky}",
          source: "bsky.brid.gy",
          author_host: "bsky.brid.gy"
        )

      twin =
        external_post(tag,
          url: "https://fed.brid.gy/r/#{bluesky}",
          source: @other_source,
          author_host: "bsky.brid.gy"
        )

      assert {:ok, :every_copy} = ExternalPosts.report(clicked.id, reporter)

      assert Repo.get!(ExternalPost, twin.id).reported_at,
             "the same post under the other bridge alias kept standing"
    end

    # One act, one row in the operator's ledger: it answers "is this one troll
    # or is this server the problem", and counting the copies we happened to
    # hold would answer a question about our own cache instead.
    test "writes one ledger row however many copies it took", %{reporter: reporter} do
      tag = followed_tag()
      url = original("4713")
      clicked = copy(tag, url, @source)
      copy(tag, url, @other_source)

      assert {:ok, :every_copy} = ExternalPosts.report(clicked.id, reporter)

      ledger = from(e in NoteEvent, where: e.action == "reported_post")
      assert Repo.aggregate(ledger, :count) == 1
    end

    test "a later pull cannot write the words back into a copy it already holds", %{
      reporter: reporter
    } do
      tag = followed_tag()
      stub_tag_timeline([status(%{"id" => "s1", "url" => original("s1")})])
      assert %{stored: 1} = ExternalPosts.fetch_due()

      post = Repo.one!(ExternalPost)
      assert {:ok, :every_copy} = ExternalPosts.report(post.id, reporter)

      overdue!(tag, DateTime.utc_now(:second))
      assert %{stored: 0} = ExternalPosts.fetch_due()

      row = Repo.get!(ExternalPost, post.id)
      assert row.reported_at
      assert row.text == ""
    end

    # The tombstone only stops the row it sits on from being rewritten. A tag
    # nobody followed at the time of the report is a **new** (tag, server) pair,
    # so the same status arrives as a fresh row with its words intact — the
    # promise broken with one extra step. The gate is on the way in.
    test "a copy arriving under a tag followed later is refused", %{reporter: reporter} do
      _one = followed_tag()
      stub_tag_timeline([status(%{"id" => "s1", "url" => original("s1")})])
      assert %{stored: 1} = ExternalPosts.fetch_due()

      assert {:ok, :every_copy} = ExternalPosts.report(Repo.one!(ExternalPost).id, reporter)

      _two = followed_tag()
      assert %{stored: 0} = ExternalPosts.fetch_due()

      assert Repo.aggregate(ExternalPost, :count) == 1
      assert Repo.one!(ExternalPost).text == ""
    end

    # The gate compares the key, not the column. Comparing the two strings let
    # the same post back in the moment a server spelled its address with one
    # character more.
    test "a variant spelling of a reported address is refused too", %{reporter: reporter} do
      tag = followed_tag()
      stub_tag_timeline([status(%{"id" => "s1", "url" => original("s1")})])
      assert %{stored: 1} = ExternalPosts.fetch_due()

      assert {:ok, :every_copy} = ExternalPosts.report(Repo.one!(ExternalPost).id, reporter)

      # The same status, one trailing slash and a fragment later.
      stub_tag_timeline([status(%{"id" => "s2", "url" => original("s1") <> "/#comments"})])
      overdue!(tag, DateTime.utc_now(:second))
      assert %{stored: 0} = ExternalPosts.fetch_due()

      assert Repo.aggregate(ExternalPost, :count) == 1
    end

    # A row the release before #2127 wrote carries no author host, so it has no
    # key — and nothing can be a copy of it, itself included. Without a clause
    # of its own the report blanked nothing at all and still answered `:ok`.
    test "a row from before the author host was stored takes itself down", %{reporter: reporter} do
      tag = followed_tag()
      post = external_post(tag, url: original("4730"), source: @source, author_host: nil)

      assert {:ok, :this_copy} = ExternalPosts.report(post.id, reporter)

      row = Repo.get!(ExternalPost, post.id)
      assert row.reported_at, "the report wrote a ledger entry and took nothing down"
      assert row.text == ""
    end

    test "the tombstone outlives both caps", %{reporter: reporter} do
      put_config(:external_tag_post_caps, per_tag: 1, total: 1)
      tag = followed_tag()

      reported =
        external_post(tag,
          source: @source,
          author_host: @source,
          url: original("4715"),
          published_at: ~U[2026-08-01 10:00:00Z]
        )

      assert {:ok, :every_copy} = ExternalPosts.report(reported.id, reporter)

      # Newer rows arrive and both trims run over the table.
      stub_tag_timeline([status(%{"id" => "s9", "created_at" => "2026-08-20T10:00:00.000Z"})])
      assert %{stored: 1} = ExternalPosts.fetch_due()
      ExternalPosts.enforce_ceiling()

      assert Repo.get(ExternalPost, reported.id)
    end
  end

  # The key itself, asked directly: each rule below is a spelling the same post
  # really arrived under, and every one of them decides whose words a report
  # blanks.
  describe "the origin key" do
    test "the author's server is half of it" do
      assert key("https://#{@source}/@ada/1", @source) !=
               key("https://#{@source}/@ada/1", "x.test")
    end

    test "a trailing slash, a fragment and the host's case are the same address" do
      canonical = key("https://#{@source}/@ada/1")

      assert key("https://#{@source}/@ada/1/") == canonical
      assert key("https://#{@source}/@ada/1#comments") == canonical
      assert key("https://#{String.upcase(@source)}/@ada/1") == canonical
      assert key("https://www.#{@source}/@ada/1") == canonical
      assert key("https://#{@source}./@ada/1") == canonical
    end

    test "the path keeps its case, where two spellings are two posts" do
      refute key("https://#{@source}/@ada/AbC") == key("https://#{@source}/@ada/abc")
    end

    test "the query stays, where a post may be named in it" do
      refute key("https://#{@source}/notes?id=1") == key("https://#{@source}/notes?id=2")
    end

    test "a redirect wrapper is the address it wraps, encoded or not" do
      wrapped = "https://bsky.app/profile/did:plc:abc/post/3mv2azzztuk2i"

      assert key("https://bsky.brid.gy/r/#{wrapped}") == key(wrapped)
      assert key("https://fed.brid.gy/r/#{wrapped}") == key(wrapped)
      assert key("https://fed.brid.gy/r/#{URI.encode_www_form(wrapped)}") == key(wrapped)
    end

    # A query parameter is where a server puts somebody else's address for its
    # own reasons, so unwrapping one would relate two unrelated posts.
    test "an address in the query is not a wrapper" do
      other = "https://elsewhere.test/@bob/9"

      refute key("https://#{@source}/read?url=#{other}") == key(other)
    end
  end

  # Which rows may speak for a copy they did not file. The one field an answer
  # cannot write is *which* server answered, so the test is that the server we
  # asked, the address and the author all name it.
  describe "the post's own copy" do
    test "the server we asked, the address and the author naming one server" do
      assert ExternalPost.home_copy?(row(url: "https://#{@source}/@ada/1"))
    end

    test "a relayed post is somebody else's word about it" do
      refute ExternalPost.home_copy?(row(url: "https://#{@source}/@ada/1", source: @other_source))
    end

    # The forgery the revert was for: the address and the author agree with each
    # other and with nothing else, because one server wrote both of them.
    test "an address and an author a third server claims together" do
      refute ExternalPost.home_copy?(
               row(url: "https://#{@source}/@ada/1", source: "impostor.example")
             )
    end

    test "a post at an address on a server other than the author's" do
      refute ExternalPost.home_copy?(row(url: "https://elsewhere.test/@ada/1"))
    end

    test "the www. alias and the host's case are the same server" do
      assert ExternalPost.home_copy?(
               row(url: "https://www.#{@source}/@ada/1", source: "WWW.#{@source}.")
             )
    end

    # The wrapper is an address on the bridge, and what it wraps is somebody
    # else's by construction — so the raw address is what has to agree.
    test "a bridge's own wrapper address is its own" do
      assert ExternalPost.home_copy?(
               row(
                 url: "https://bsky.brid.gy/r/https://bsky.app/profile/x/post/1",
                 source: "bsky.brid.gy",
                 author_host: "bsky.brid.gy"
               )
             )
    end

    test "fails closed on a row with no author host and on an unusable address" do
      refute ExternalPost.home_copy?(row(url: "https://#{@source}/@ada/1", author_host: nil))
      refute ExternalPost.home_copy?(row(url: "not an address"))
    end
  end
end
