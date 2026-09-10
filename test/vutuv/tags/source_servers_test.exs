defmodule Vutuv.Tags.SourceServersTest do
  @moduledoc """
  What the tag-source panel offers and what it accepts (issue #2128).

  The gate here is the member's answer, not the fetcher's guard: every one of
  its refusals runs again at fetch time, where the blocklist and the SSRF vet
  are authoritative. What this file pins is that a server joins a follow's list
  only after it has actually answered, and that the four things which can change
  without anybody asking — the flag, the blocklist, the server name, `https` —
  are re-decided on every press.

  `async: false`: it flips `:tag_source_servers`, `:fetch_external_tag_posts`,
  `:external_tag_req_options` and `:ssrf_resolver`, all of which are application
  env and therefore global — see `Vutuv.Tags.ExternalTagClientTest`, which flips
  the same seam.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.ExternalTagHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Tags
  alias Vutuv.Tags.SourceServer
  alias Vutuv.Tags.SourceServers

  @good "troet.example"
  @locked "chaos.example"

  setup do
    put_config(:fetch_external_tag_posts, true)
    put_config(:tag_source_servers, [@good, @locked])

    stub_servers(%{
      @good => %{accounts: 49_157, active_month: 5_586, posts: 5_532_040, language: "de"},
      # The case two of thirteen servers are in: it answers, and says the
      # timeline is for members. Mastodon says it with 422, not 401.
      @locked => %{timeline: 422, language: "en"}
    })

    :ok
  end

  # The factory's own sequence, so calling this twice in one test is two tags
  # rather than one unique-index violation.
  defp tag, do: insert(:tag)

  describe "offered/0" do
    test "reads the configured list" do
      assert SourceServers.offered() == [@good, @locked]
    end

    test "leaves out a server the operator has shut out" do
      user = insert(:activated_user)
      {:ok, {_blocked, _purged}} = Fediverse.block_instance(%{"host" => @locked}, user)

      assert SourceServers.offered() == [@good]
    end

    test "offers nothing when this installation may not call out" do
      put_config(:fetch_external_tag_posts, false)

      assert SourceServers.offered() == []
    end

    test "offers nothing when the operator named no servers" do
      put_config(:tag_source_servers, [])

      assert SourceServers.offered() == []
    end
  end

  describe "check/2" do
    test "accepts a server that answers, and stores what it says about itself" do
      assert {:ok, @good} = SourceServers.check(@good, tag())

      info = Repo.get_by!(SourceServer, host: @good)
      assert info.status == "ok"
      assert info.accounts == 49_157
      assert info.active_month == 5_586
      assert info.posts == 5_532_040
      assert info.language == "de"
      assert info.description == "Hallo im Beispiel-Server!"
    end

    test "reads an address, a handle and a www. spelling as the same server" do
      assert {:ok, @good} = SourceServers.check("https://#{@good}/tags/koblenz", tag())
      assert {:ok, @good} = SourceServers.check("@ada@#{@good}", tag())
      assert {:ok, @good} = SourceServers.check("www.#{@good}", tag())
    end

    test "refuses a server that only serves its timeline to members" do
      assert {:error, {:account_required, @locked}} = SourceServers.check(@locked, tag())

      # Stored all the same: the panel has to be able to say *why* it is greyed
      # out, and asking again on the next render would answer the same thing.
      assert Repo.get_by!(SourceServer, host: @locked).status == "account_required"
    end

    test "refuses a server that does not answer at all" do
      assert {:error, {:unreachable, "nobody.example"}} =
               SourceServers.check("nobody.example", tag())
    end

    test "refuses http, rather than quietly making it https" do
      assert {:error, :insecure} = SourceServers.check("http://#{@good}", tag())
      refute Repo.get_by(SourceServer, host: @good)
    end

    test "refuses something that is not a server name, without asking anybody" do
      assert {:error, {:not_a_server, "   "}} = SourceServers.check("   ", tag())

      # `URI.parse/1` is lenient enough to call this a host, so without the
      # literal grammar check ahead of the probe it reads as a server that did
      # not answer — and costs a request on the way to that wrong message.
      # Calibrated: without it the answer is `{:error, {:unreachable, …}}`.
      assert {:error, {:not_a_server, "was soll das"}} =
               SourceServers.check("was soll das", tag())

      refute_received {:req, _host, _path}
    end

    test "refuses an internal address before asking it anything" do
      assert {:error, {:internal, "169.254.169.254"}} =
               SourceServers.check("169.254.169.254", tag())

      refute_received {:req, _host, _path}
    end

    test "refuses this installation, which is on anyway" do
      assert {:error, :local} = SourceServers.check(VutuvWeb.Endpoint.host(), tag())
    end

    test "refuses a server the operator has shut out" do
      user = insert(:activated_user)
      {:ok, {_blocked, _purged}} = Fediverse.block_instance(%{"host" => @good}, user)

      assert {:error, {:blocked, @good}} = SourceServers.check(@good, tag())
      refute_received {:req, @good, _path}
    end

    test "refuses a name that resolves to an internal address" do
      # The changeset's check is literal and cannot resolve, so this is the only
      # layer that catches a public-looking name pointing at the metadata
      # service. Calibrated: with `Http.get_pinned/4`'s vet removed the probe
      # answers `{:ok, host}` instead.
      put_config(:ssrf_resolver, fn _host, _family -> {:ok, [{169, 254, 169, 254}]} end)

      assert {:error, {:internal, @good}} = SourceServers.check(@good, tag())
    end

    test "asks nobody anything when this installation may not call out" do
      put_config(:fetch_external_tag_posts, false)

      assert {:error, :disabled} = SourceServers.check(@good, tag())
      refute_received {:req, _host, _path}
    end

    test "accepts a server that serves its timeline but publishes no NodeInfo" do
      # The timeline alone answers the question the panel asks. Gating on
      # NodeInfo would make the panel stricter than the fetcher, on a document
      # that only supplies the figures beside the switch.
      stub_servers(%{"plain.example" => %{nodeinfo_href: "https://elsewhere.example/x"}})

      assert {:ok, "plain.example"} = SourceServers.check("plain.example", tag())

      info = Repo.get_by!(SourceServer, host: "plain.example")
      assert info.status == "ok"
      assert is_nil(info.accounts)
      assert is_nil(info.node_name)
    end

    test "does not follow a NodeInfo link that names another server" do
      # The link document is written by the server being probed. The pin keeps
      # the second request on the vetted address whatever the href says, so what
      # this refuses is *fabricating* a request the document never described:
      # reading somebody else's URL as a path on this server and calling
      # whatever comes back its NodeInfo. Calibrated: without the host check the
      # answer is `{:ok, "troet.example"}`.
      stub_servers(%{@good => %{nodeinfo_href: "https://elsewhere.example/nodeinfo/2.0"}})

      assert {:ok, @good} = SourceServers.check(@good, tag())
      refute_received {:req, "elsewhere.example", _path}
      assert is_nil(Repo.get_by!(SourceServer, host: @good).accounts)
    end

    test "keeps a healthy server healthy when its NodeInfo document blows up" do
      # The figures are decoration and the timeline alone decides. A blanket
      # rescue over the whole probe made *any* exception in the optional leg
      # mark the server "unreachable" for a day — and a stranger's document is
      # exactly where an exception comes from: `to_string/1` on a `rel` that is
      # an object raises `Protocol.UndefinedError`. Calibrated: with the rescue
      # left blanket the status is "unreachable" and nothing can be picked.
      stub_servers(%{@good => %{nodeinfo_links: [%{"rel" => %{}, "href" => "x"}]}})

      assert {:ok, @good} = SourceServers.check(@good, tag())

      info = Repo.get_by!(SourceServer, host: @good)
      assert info.status == "ok"
      assert is_nil(info.accounts)
    end

    test "keeps a server whose NodeInfo counts do not fit in a column" do
      # A count from a stranger, above what `bigint` holds. `start_async`
      # catches it on the panel's refresh path; on this one it would come out of
      # the member's own `handle_event` and take their feed with it. Calibrated:
      # without the upper bound the insert raises rather than answering.
      stub_servers(%{@good => %{accounts: 9_300_000_000_000_000_000}})

      assert {:ok, @good} = SourceServers.check(@good, tag())

      info = Repo.get_by!(SourceServer, host: @good)
      assert info.status == "ok"
      assert is_nil(info.accounts)
      assert info.active_month == 5_586
    end

    test "refuses a hostname longer than a hostname, without asking anybody" do
      # `maxlength="255"` is markup, not a guard. Without the length in the
      # grammar this costs two outbound requests on the way to storing nothing,
      # and tells the member "did not answer" where the truth is "that is not a
      # server name". Calibrated: without it the answer is
      # `{:error, {:unreachable, …}}`.
      long = String.duplicate("a", 250) <> ".example"

      assert {:error, {:not_a_server, ^long}} = SourceServers.check(long, tag())
      refute_received {:req, _host, _path}
    end
  end

  describe "refresh/2" do
    test "asks a server and leaves an answer nobody has to ask for again today" do
      assert %{@good => %SourceServer{status: "ok"} = info} =
               SourceServers.refresh([@good], tag())

      assert_received {:req, @good, "/.well-known/nodeinfo"}

      # Which hosts are stale is the caller's to decide — the panel holds the
      # rows already — so what this pins is that the stored answer says it is
      # fresh, which is what keeps the panel from asking on the next render.
      assert SourceServers.fresh?(info)
    end

    test "stamps the clock on a server that could not be reached" do
      # Otherwise it is due again on the very next render, forever — the
      # sweeper-clock trap (#1316) in a panel.
      assert %{"nobody.example" => %SourceServer{status: "unreachable"}} =
               SourceServers.refresh(["nobody.example"], tag())
    end

    test "asks nothing when this installation may not call out" do
      put_config(:fetch_external_tag_posts, false)

      assert SourceServers.refresh([@good], tag()) == %{}
      refute_received {:req, _host, _path}
    end
  end

  describe "rows/1" do
    test "puts this installation first, then what the follow names, then the offers" do
      assert [local, picked | rest] = SourceServers.rows([Tags.local_tag_follow_source(), @good])

      assert local.local?
      assert local.picked?
      assert picked.host == @good
      assert picked.picked?
      assert Enum.map(rest, & &1.host) == [@locked]
      refute Enum.any?(rest, & &1.picked?)
    end

    test "keeps a picked server visible after the operator shuts it out" do
      user = insert(:activated_user)
      {:ok, {_blocked, _purged}} = Fediverse.block_instance(%{"host" => @good}, user)

      rows = SourceServers.rows([Tags.local_tag_follow_source(), @good])
      row = Enum.find(rows, &(&1.host == @good))

      assert row.picked?
      assert row.blocked?
    end
  end

  describe "the cap" do
    test "a follow may name the configured number of other servers and no more" do
      user = insert(:activated_user)
      {:ok, follow} = Tags.follow_tag(user, tag())
      limit = SourceServers.limit()

      for n <- 1..limit do
        assert {:ok, _row} = Tags.add_tag_follow_source(follow, "server#{n}.example")
      end

      assert {:error, :too_many_sources} =
               Tags.add_tag_follow_source(follow, "onemore.example")

      # This installation is always on and never spends a slot.
      assert length(Tags.tag_follow_sources(follow)) == limit + 1
    end

    test "adding a server the follow already names stays idempotent at the cap" do
      user = insert(:activated_user)
      {:ok, follow} = Tags.follow_tag(user, tag())

      for n <- 1..SourceServers.limit() do
        assert {:ok, _row} = Tags.add_tag_follow_source(follow, "server#{n}.example")
      end

      assert {:ok, _row} = Tags.add_tag_follow_source(follow, "server1.example")
    end
  end
end
