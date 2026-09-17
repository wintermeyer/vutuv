defmodule Vutuv.Tags.TrendingTest do
  @moduledoc """
  What the tag card offers as "suddenly busy on other servers" (issue #2129).

  Every claim here was calibrated against the ten servers `config/config.exs`
  ships, on 10 September 2026 — see `Vutuv.Tags.Trending`'s moduledoc for the
  figures. The fixtures are those measurements shrunk to two servers.

  `async: false`: it flips `:fetch_external_tag_posts`, `:fetch_trending_tags`,
  `:tag_source_servers`, `:tag_trending` and `:external_tag_req_options`, every
  one of them application env and therefore global.
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
  alias Vutuv.Tags.TrendingTag

  @big "troet.example"
  @small "nrw.example"

  # The shapes the real endpoint returned, newest day first. `warntag` stood at
  # 1,084 uses against a median of 3; `xbox` at 130 against 78, which is a busy
  # tag and not a sudden one; `mow4` came from nowhere and was a bot farm.
  @warntag [1084, 16, 11, 3, 1, 3, 2]
  @xbox [130, 123, 87, 69, 40, 54, 117]
  @mow4 [805, 1, 0, 0, 0, 0, 0]

  # A crowd: `count` statuses over five author domains, none of them a bot.
  defp crowd(source, count \\ 20) do
    sample_statuses(source, count, ~w(a.example b.example c.example d.example e.example))
  end

  # One spiking tag, listed and sampled by both servers — whichever is busiest
  # is the one the census asks, and a fixture that answered nothing on the other
  # would be rejected for being too small and prove nothing.
  defp spiking(name, history, sample) do
    stub(
      %{@big => [{name, history}], @small => [{name, history}]},
      %{@big => %{name => sample.(@big)}, @small => %{name => sample.(@small)}}
    )
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

    # Issue #2209: an empty offer is either a quiet day or a reader who already
    # follows everything that ran ahead, and the row says different things.
    test "says whether the reader's own follows are what emptied the offer" do
      spiking("warntag", @warntag, &crowd/1)
      Trending.refresh()

      assert %{tags: [_row], all_followed?: false} = Trending.offer()
      assert %{tags: [], all_followed?: true} = Trending.offer(except: ["WarnTag"])
      assert %{tags: [_row], all_followed?: false} = Trending.offer(except: ["xbox"])

      Repo.delete_all(TrendingTag)
      assert %{tags: [], all_followed?: false} = Trending.offer(except: ["warntag"])
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
    # one thing wrong with the sample.
    defp spiking_bot_wave(sample), do: spiking("mow4", @mow4, sample)

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
      spiking_bot_wave(&crowd(&1, 5))

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

  # A post written here goes out with its hashtags, so the servers we ask hold
  # it and hand it back — and until #2196 it counted as one more independent
  # author server on the very gate meant to catch a single source. The live
  # figures behind each of these are in `Vutuv.Tags.ExternalTagClient`.
  describe "our own echo is not one of the servers out there" do
    defp spiking_with(sample), do: spiking("warntag", @warntag, sample)

    # Our own statuses, from the one fixture that knows what those look like.
    # Their ids are distinct from `sample_statuses/4`'s, because the two lists
    # are concatenated into one timeline.
    defp echo(source, count) do
      Enum.map(1..count, &our_status(source, %{id: "echo#{&1}"}))
    end

    test "a tag that reaches the fourth author server only through us is not offered" do
      # Three servers out there and this one: four domains, and the gate wants
      # four. Ours is the one that must not count.
      spiking_with(&(sample_statuses(&1, 15, ~w(a.example b.example c.example)) ++ echo(&1, 5)))

      Trending.refresh()

      assert Trending.offers() == []
    end

    test "the same tag with a genuine fourth server is offered" do
      spiking_with(
        &(sample_statuses(&1, 16, ~w(a.example b.example c.example d.example)) ++ echo(&1, 5))
      )

      Trending.refresh()

      assert [row] = Trending.offers()
      assert row.name == "warntag"
      # The stored figures are about strangers only — 16 statuses over four
      # servers, with our five nowhere in them.
      assert row.author_hosts == 4
      assert row.sampled == 16
    end

    test "a tag this installation is busy with and nobody else is not offered" do
      # troet.cafe's `#vutuv`, shrunk: five foreign statuses over five servers
      # under thirty of our own. The author servers alone would still clear the
      # gate — five is more than four — so what catches it is that there is
      # almost nothing out there to judge.
      spiking_with(
        &(sample_statuses(&1, 5, ~w(a.example b.example c.example d.example e.example)) ++
            echo(&1, 30))
      )

      Trending.refresh()

      assert Trending.offers() == []
    end

    test "our own posts do not water down the share that is bots" do
      # Eight bots among ten strangers is a wave. Counted beside ten posts of
      # ours it reads as 40 %, which is inside the threshold.
      spiking_with(
        &(sample_statuses(&1, 10, ~w(a.example b.example c.example d.example), 8) ++
            echo(&1, 10))
      )

      Trending.refresh()

      assert Trending.offers() == []
    end
  end

  # Issue #2204: a server the operator shut out is no more a voice about a tag
  # than it is a post under one. Each fixture puts the blocked server exactly
  # where counting it would decide the verdict.
  describe "a blocked instance is not one of the servers out there" do
    @blocked "shouty.example"

    setup do
      Repo.insert!(%BlockedInstance{host: @blocked})
      :ok
    end

    # Statuses from the blocked server, with ids apart from `sample_statuses/4`'s
    # because the two lists are one timeline.
    defp from_blocked(source, count, bots) do
      source
      |> sample_statuses(count, [@blocked], bots)
      |> Enum.map(&Map.update!(&1, "id", fn id -> "blocked-#{id}" end))
    end

    defp spiking_with_blocked(sample), do: spiking("warntag", @warntag, sample)

    test "a tag that reaches the fourth author server only through a blocked one is not offered" do
      spiking_with_blocked(
        &(sample_statuses(&1, 15, ~w(a.example b.example c.example)) ++ from_blocked(&1, 5, 0))
      )

      Trending.refresh()

      assert Trending.offers() == []
    end

    test "a blocked server's bots do not make a crowd read as a wave" do
      # Ten people over four servers beside twelve bots from the blocked one:
      # counted, 12 of 22 is past the threshold and the crowd was dropped.
      spiking_with_blocked(
        &(sample_statuses(&1, 10, ~w(a.example b.example c.example d.example)) ++
            from_blocked(&1, 12, 12))
      )

      Trending.refresh()

      assert [row] = Trending.offers()
      assert row.author_hosts == 4
      assert row.bot_posts == 0
      assert row.sampled == 10
    end

    test "a blocked server's people do not water down a wave" do
      # Eight bots among ten posts is a wave; beside ten posts from the blocked
      # server it read as 40 %.
      spiking_with_blocked(
        &(sample_statuses(&1, 10, ~w(a.example b.example c.example d.example), 8) ++
            from_blocked(&1, 10, 0))
      )

      Trending.refresh()

      assert Trending.offers() == []
    end

    test "a sample without a blocked server is judged as before" do
      trends = [{"warntag", @warntag}, {"mow4", @mow4}]

      samples = fn host ->
        %{
          "warntag" => crowd(host),
          "mow4" => sample_statuses(host, 20, ~w(a.example b.example c.example d.example), 19)
        }
      end

      stub(%{@big => trends, @small => trends}, %{
        @big => samples.(@big),
        @small => samples.(@small)
      })

      Trending.refresh()

      assert [row] = Trending.offers()
      assert row.name == "warntag"
      assert row.author_hosts == 5
      assert row.bot_posts == 0
      assert row.sampled == 20
    end
  end

  # Issue #2160: the census always asked a tag's busiest server, and one real
  # pass put seven of its eighteen requests on mastodon.social.
  describe "the census is spread over the servers that report a tag" do
    @third "third.example"
    @quieter [100, 1, 1, 1, 1, 1, 1]

    # Everything the census asked this pass, as `{host, tag}`.
    defp census_requests(acc \\ []) do
      receive do
        {:req, host, "/api/v1/timelines/tag/" <> name} -> census_requests([{host, name} | acc])
        {:req, _host, _path} -> census_requests(acc)
      after
        0 -> acc
      end
    end

    test "no server is asked more than its share, and the others carry the rest" do
      put_config(:tag_source_servers, [@big, @small, @third])
      put_config(:tag_trending, census_per_host: 2)

      # Six equally loud candidates, every one busiest on the big server, three
      # of them also listed by each smaller one. The big server alone could vet
      # all six; its cap leaves it two.
      first = ~w(alpha bravo charlie)
      second = ~w(delta echo foxtrot)

      stub(
        %{
          @big => Enum.map(first ++ second, &{&1, @warntag}),
          @small => Enum.map(first, &{&1, @quieter}),
          @third => Enum.map(second, &{&1, @quieter})
        },
        %{
          @big => Map.new(first ++ second, &{&1, crowd(@big)}),
          @small => Map.new(first, &{&1, crowd(@small)}),
          @third => Map.new(second, &{&1, crowd(@third)})
        }
      )

      Trending.refresh()

      asked = census_requests()
      per_host = Enum.frequencies_by(asked, &elem(&1, 0))

      assert per_host == %{@big => 2, @small => 1, @third => 2}

      # The last candidate is reported by two servers that have both had their
      # share, so it waits for the next pass rather than being asked of either.
      refute Enum.any?(asked, &match?({_host, "foxtrot"}, &1))

      assert Trending.offers(limit: 10) |> Enum.map(& &1.name) |> Enum.sort() ==
               ~w(alpha bravo charlie delta echo)
    end
  end

  describe "the knobs" do
    test "are read from the application env, and a key it does not name keeps its default" do
      put_config(:tag_trending, min_servers: 1)

      assert Trending.settings()[:min_servers] == 1
      assert Trending.settings()[:min_uses] == 25
      assert Trending.settings()[:census_per_host] == 2
    end

    test "an installation reading one server offers what spikes there once it says so" do
      put_config(:tag_source_servers, [@big])
      stub(%{@big => [{"warntag", @warntag}]}, %{@big => %{"warntag" => crowd(@big)}})

      Trending.refresh()
      assert Trending.offers() == []

      put_config(:tag_trending, min_servers: 1)
      Repo.delete_all(TrendCheck)
      Trending.refresh()

      assert [%{name: "warntag"}] = Trending.offers()
    end

    test "every one of them can be set from the environment and is documented" do
      runtime = File.read!("config/runtime.exs")
      admins = File.read!("docs/ADMINS.md")
      named = Regex.scan(~r/\{"(TAG_TRENDING_[A-Z_]+)", :([a-z_]+)\}/, runtime)

      assert named |> Enum.map(&Enum.at(&1, 2)) |> Enum.sort() ==
               Trending.settings() |> Keyword.keys() |> Enum.map(&to_string/1) |> Enum.sort()

      for [_match, name, _key] <- named do
        assert admins =~ "| `#{name}` |",
               "#{name} is missing from the env table in docs/ADMINS.md"
      end
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
