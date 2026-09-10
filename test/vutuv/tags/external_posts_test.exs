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
  alias Vutuv.Repo
  alias Vutuv.Tags
  alias Vutuv.Tags.ExternalFetch
  alias Vutuv.Tags.ExternalPost
  alias Vutuv.Tags.ExternalPosts
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
end
