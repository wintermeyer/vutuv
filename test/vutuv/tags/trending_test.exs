defmodule Vutuv.Tags.TrendingTest do
  @moduledoc """
  What the tag card offers as "suddenly busy on other servers" (issue #2129).

  Every claim here was calibrated against the ten servers `config/config.exs`
  ships, on 10 September 2026 — see `Vutuv.Tags.Trending`'s moduledoc for the
  figures. The fixtures are those measurements shrunk to two servers.

  `async: false`: it flips `:fetch_external_tag_posts`, `:fetch_trending_tags`,
  `:tag_source_servers` and `:external_tag_req_options`, every one of them
  application env and therefore global.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.ExternalTagHelpers

  alias Vutuv.Fediverse.BlockedInstance
  alias Vutuv.Repo
  alias Vutuv.Tags
  alias Vutuv.Tags.ExternalFetch
  alias Vutuv.Tags.ExternalPosts
  alias Vutuv.Tags.TrendCheck
  alias Vutuv.Tags.Trending

  @big "troet.example"
  @small "nrw.example"

  # The shapes the real endpoint returned, newest day first. `warntag` stood at
  # 1,084 uses against a median of 3; `xbox` at 130 against 78, which is a busy
  # tag and not a sudden one; `mow4` came from nowhere and was a bot farm.
  @warntag [1084, 16, 11, 3, 1, 3, 2]
  @xbox [130, 123, 87, 69, 40, 54, 117]
  @mow4 [805, 1, 0, 0, 0, 0, 0]

  # A crowd: twenty statuses over five author domains, none of them a bot.
  defp crowd(source) do
    sample_statuses(source, 20, ~w(a.example b.example c.example d.example e.example))
  end

  # The stub reports every request back here, so "nobody was asked" has to be
  # asserted on an empty mailbox rather than on one holding the last pass's.
  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end

  setup do
    put_config(:fetch_external_tag_posts, true)
    put_config(:fetch_trending_tags, true)
    put_config(:tag_source_servers, [@big, @small])
    :ok
  end

  defp stub(trends_by_host, samples \\ %{}, extra \\ %{}) do
    servers =
      Map.new(trends_by_host, fn {host, trends} ->
        attrs = %{trends: trends, samples: Map.get(samples, host, %{})}
        {host, Map.merge(attrs, Map.get(extra, host, %{}))}
      end)

    stub_servers(servers)
  end

  describe "what is offered" do
    test "a tag spiking on several servers is offered, with its week beside it" do
      stub(
        %{@big => [{"warntag", @warntag}], @small => [{"warntag", @warntag}]},
        %{@big => %{"warntag" => crowd(@big)}, @small => %{"warntag" => crowd(@small)}}
      )

      Trending.refresh()

      assert [row] = Trending.offers()
      assert row.name == "warntag"
      assert row.servers == 2
      assert row.uses == 2 * 1084
      assert row.baseline == 2 * 3
      assert row.history == Enum.map(@warntag, &(&1 * 2))
      assert @big in row.hosts
    end

    test "a tag on one server alone is not offered" do
      stub(
        %{@big => [{"warntag", @warntag}], @small => []},
        %{@big => %{"warntag" => crowd(@big)}}
      )

      Trending.refresh()

      assert Trending.offers() == []
    end

    test "the seven-day history decides, not the raw volume" do
      # `xbox` is the calibration case: 130 uses today is more than most tags
      # ever see, and it is exactly what that tag does every day.
      stub(
        %{
          @big => [{"xbox", @xbox}, {"warntag", @warntag}],
          @small => [{"xbox", @xbox}, {"warntag", @warntag}]
        },
        %{
          @big => %{"xbox" => crowd(@big), "warntag" => crowd(@big)},
          @small => %{"xbox" => crowd(@small), "warntag" => crowd(@small)}
        }
      )

      Trending.refresh()

      assert Enum.map(Trending.offers(), & &1.name) == ["warntag"]
    end
  end

  describe "the loudest tag is often a machine" do
    # `mow4` clears every gate that reads the trending list — it came from
    # nowhere and it trended on both servers — so each of these leaves exactly
    # one thing wrong with the sample. The sample is stubbed on **both** servers
    # because whichever is busiest is the one asked, and a fixture that answered
    # nothing would be rejected for being too small and prove nothing.
    defp spiking_bot_wave(sample) do
      stub(
        %{@big => [{"mow4", @mow4}], @small => [{"mow4", @mow4}]},
        %{@big => %{"mow4" => sample.(@big)}, @small => %{"mow4" => sample.(@small)}}
      )
    end

    test "a tag whose authors are all one domain is not offered" do
      spiking_bot_wave(&sample_statuses(&1, 20, ["social.prepedia.example"]))

      Trending.refresh()

      assert Trending.offers() == []
    end

    test "a tag whose posts are bot accounts is not offered" do
      spiking_bot_wave(&sample_statuses(&1, 20, ~w(a.example b.example c.example d.example), 19))

      Trending.refresh()

      assert Trending.offers() == []
    end

    test "a tag with too small a sample to judge is not offered" do
      # Five statuses over five domains and not a bot among them: every other
      # gate is happy, and five is simply not enough to tell a crowd from a
      # machine. Failing closed is the only safe direction.
      spiking_bot_wave(
        &sample_statuses(&1, 5, ~w(a.example b.example c.example d.example e.example))
      )

      Trending.refresh()

      assert Trending.offers() == []
    end

    test "a tag whose server will not show its timeline is not offered" do
      # Three of eighteen servers serve their trending list to anybody and their
      # tag timeline only to somebody logged in (#2128). There is no sample to
      # judge such a tag on, so it is not offered.
      stub(
        %{@big => [{"mow4", @mow4}], @small => [{"mow4", @mow4}]},
        %{},
        %{@big => %{timeline: 422}, @small => %{timeline: 422}}
      )

      Trending.refresh()

      assert Trending.offers() == []
    end

    test "a crowd over the same numbers is offered" do
      # The other side of all four: the same spike, sampled as a real crowd.
      spiking_bot_wave(&crowd/1)

      Trending.refresh()

      assert [row] = Trending.offers()
      assert row.name == "mow4"
      assert row.author_hosts == 5
      assert row.bot_posts == 0
      assert row.sampled == 20
    end
  end

  describe "the clock" do
    test "is stamped on every outcome, so a server that can never answer leaves the due set" do
      # A server the operator named that does not serve a trending list at all —
      # not every fediverse server is Mastodon. Nothing about it will change in
      # two minutes, and nothing is learned about it, so it is the exact item
      # that holds the front of every pass forever if its clock never moves.
      stub(
        %{@big => [{"warntag", @warntag}], @small => []},
        %{@big => %{"warntag" => crowd(@big)}},
        %{@small => %{trends_status: 404}}
      )

      assert Enum.sort(Trending.due_servers()) == Enum.sort([@big, @small])

      Trending.refresh()

      assert Trending.due_servers() == []
      assert Repo.get_by!(TrendCheck, host: @small).last_outcome == "skipped"
      assert Repo.get_by!(TrendCheck, host: @big).last_outcome == "listed"
    end

    test "a server the operator blocked is not even offered" do
      Repo.insert!(%BlockedInstance{host: @small})
      stub(%{@big => [], @small => []})

      assert Trending.due_servers() == [@big]

      Trending.refresh()

      assert Repo.get_by(TrendCheck, host: @small) == nil
    end

    test "a server that answers nothing usable is stamped too" do
      stub(%{@big => [], @small => []})

      Trending.refresh()

      assert Trending.due_servers() == []
      assert Repo.get_by!(TrendCheck, host: @big).last_outcome == "empty"
    end

    test "a pass with nothing due asks nobody and leaves the offer alone" do
      stub(
        %{@big => [{"warntag", @warntag}], @small => [{"warntag", @warntag}]},
        %{@big => %{"warntag" => crowd(@big)}, @small => %{"warntag" => crowd(@small)}}
      )

      Trending.refresh()
      assert [_row] = Trending.offers()

      flush()
      Trending.refresh()

      refute_received {:req, _host, _path}
      assert [_row] = Trending.offers()
    end
  end

  describe "a spike shortens the pull" do
    test "a followed tag seen spiking is due at once" do
      name = "warntag"
      tag = insert(:tag, name: name, slug: name)
      user = insert(:user)
      follow_tag_through(user, tag, @big)

      later = DateTime.add(DateTime.utc_now(:second), 3_000)

      Repo.insert!(%ExternalFetch{
        tag_id: tag.id,
        source: @big,
        checked_at: DateTime.utc_now(:second),
        next_fetch_at: later,
        interval_seconds: 10_800
      })

      stub(
        %{@big => [{name, @warntag}], @small => [{name, @warntag}]},
        %{@big => %{name => crowd(@big)}, @small => %{name => crowd(@small)}}
      )

      Trending.refresh()

      schedule = Repo.get_by!(ExternalFetch, tag_id: tag.id, source: @big)
      assert DateTime.compare(schedule.next_fetch_at, later) == :lt
      assert schedule.interval_seconds == ExternalPosts.cadence()[:min_seconds]
    end
  end

  describe "the flag" do
    test "off means no request at all" do
      put_config(:fetch_trending_tags, false)
      stub(%{@big => [{"warntag", @warntag}], @small => [{"warntag", @warntag}]})

      assert Trending.refresh() == :disabled
      refute_received {:req, _host, _path}
      assert Trending.offers() == []
      assert Trending.due_servers() == []
    end

    test "the pull's own switch takes it too" do
      put_config(:fetch_external_tag_posts, false)
      stub(%{@big => [{"warntag", @warntag}]})

      assert Trending.refresh() == :disabled
      refute_received {:req, _host, _path}
    end

    test "an installation that names no servers asks nobody" do
      put_config(:tag_source_servers, [])
      stub(%{@big => [{"warntag", @warntag}]})

      Trending.refresh()

      refute_received {:req, _host, _path}
      assert Trending.offers() == []
    end
  end

  describe "following what is offered" do
    setup do
      stub(
        %{@big => [{"warntag", @warntag}], @small => [{"warntag", @warntag}]},
        %{@big => %{"warntag" => crowd(@big)}, @small => %{"warntag" => crowd(@small)}}
      )

      Trending.refresh()
      %{user: insert(:user)}
    end

    test "mints the tag and names the servers it is busy on", %{user: user} do
      assert {:ok, tag} = Trending.follow(user, "warntag")
      assert tag.slug == "warntag"
      assert Tags.tag_followed?(user, tag)

      follow = Tags.tag_follow(user, tag.id)
      sources = Tags.tag_follow_sources(follow)

      assert Tags.local_tag_follow_source() in sources
      assert @big in sources
    end

    test "refuses a name nobody is offering", %{user: user} do
      assert Trending.follow(user, "something-else") == {:error, :not_offered}
      assert Tags.followed_tags(user) == []
    end
  end
end
