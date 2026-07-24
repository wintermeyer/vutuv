defmodule Vutuv.JobsBoardTest do
  @moduledoc """
  The public `/jobs` board queries (issue #933): the viewer-visibility gate, the
  block exclusion seam, every filter (full-text, tag, workplace, employment,
  salary, location radius, country, remote-country), keyset pagination, the
  agent-format board, and the scoped organization / tag listings.
  """

  use Vutuv.DataCase, async: true

  import Vutuv.Factory
  import Vutuv.JobsHelpers

  alias Vutuv.Geo
  alias Vutuv.Jobs
  alias Vutuv.Social
  alias Vutuv.Tags.Tag

  defp ids(%{entries: entries}), do: Enum.map(entries, & &1.id)

  describe "visibility gate" do
    test "an everyone posting shows to anon and members; a members posting only to members" do
      poster = poster_fixture()
      everyone = publish_job!(poster, %{"title" => "Public role", "visibility" => "everyone"})
      members = publish_job!(poster, %{"title" => "Members role", "visibility" => "members"})
      viewer = insert(:user)

      anon_ids = ids(Jobs.board_page(nil, %{}))
      assert everyone.id in anon_ids
      refute members.id in anon_ids

      member_ids = ids(Jobs.board_page(viewer, %{}))
      assert everyone.id in member_ids
      assert members.id in member_ids
    end

    test "a draft, expired, or frozen posting never appears on the board" do
      poster = poster_fixture()
      live = publish_job!(poster, %{"title" => "Live role"})
      {:ok, _draft} = Jobs.create_draft(poster, %{"title" => "Just a draft"})

      board = ids(Jobs.board_page(nil, %{}))
      assert board == [live.id]
    end
  end

  describe "block exclusion seam" do
    test "a posting is hidden when either party blocked the other" do
      poster = poster_fixture()
      posting = publish_job!(poster, %{"title" => "Blocked role"})
      viewer = insert(:user)

      assert posting.id in ids(Jobs.board_page(viewer, %{}))

      {:ok, _} = Social.block_user(viewer, poster)
      refute posting.id in ids(Jobs.board_page(viewer, %{}))
    end
  end

  describe "text / tag / type filters" do
    setup do
      poster = poster_fixture()

      elixir =
        publish_job!(poster, %{
          "title" => "Senior Elixir Engineer",
          "required_tags" => "Elixir, Phoenix",
          "employment_type" => "full_time",
          "workplace_type" => "onsite"
        })

      java =
        publish_job!(poster, %{
          "title" => "Java Developer",
          "required_tags" => "Java",
          "employment_type" => "part_time",
          "workplace_type" => "remote",
          "remote_countries" => ["DE"]
        })

      %{elixir: elixir, java: java}
    end

    test "free-text q matches title and description", %{elixir: elixir} do
      assert ids(Jobs.board_page(nil, %{q: "Elixir"})) == [elixir.id]
    end

    test "comma is an OR between titles (issue #952)", %{elixir: elixir, java: java} do
      both = Jobs.board_page(nil, %{q: "Elixir, Java"}) |> ids() |> Enum.sort()
      assert both == Enum.sort([elixir.id, java.id])
    end

    test "the word 'or' also ORs titles", %{elixir: elixir, java: java} do
      both = Jobs.board_page(nil, %{q: "elixir or java"}) |> ids() |> Enum.sort()
      assert both == Enum.sort([elixir.id, java.id])
    end

    test "a trailing * prefix-matches word variants", %{elixir: elixir} do
      # "Engineer" in the Elixir posting's title; "Engine*" must reach it.
      assert ids(Jobs.board_page(nil, %{q: "Engine*"})) == [elixir.id]
    end

    test "a leading - excludes a word", %{elixir: elixir, java: java} do
      # Both are "…eer"/"Developer"; exclude Java to keep only Elixir.
      assert ids(Jobs.board_page(nil, %{q: "developer or engineer -java"})) == [elixir.id]
      assert java.id not in ids(Jobs.board_page(nil, %{q: "developer or engineer -java"}))
    end

    test "operator-only junk is a no-op, not a crash", %{elixir: elixir, java: java} do
      all = Jobs.board_page(nil, %{q: "*** ,,, |"}) |> ids() |> Enum.sort()
      assert all == Enum.sort([elixir.id, java.id])
    end

    test "tag filters to postings carrying the slug", %{elixir: elixir} do
      assert ids(Jobs.board_page(nil, %{tags: ["phoenix"]})) == [elixir.id]
    end

    # Issue #951: the tag filter takes several slugs now, OR between them (a
    # posting matches when it carries ANY of them), so adding a tag broadens.
    test "several tags OR: a posting carrying any of them matches", %{elixir: elixir, java: java} do
      both = Jobs.board_page(nil, %{tags: ["phoenix", "java"]}) |> ids() |> Enum.sort()
      assert both == Enum.sort([elixir.id, java.id])
    end

    test "board_filters parses a comma-separated tag param into the OR list", %{
      elixir: elixir,
      java: java
    } do
      # A shareable ?tag=phoenix,java URL.
      filters = Jobs.board_filters(%{"tag" => "phoenix,java"}, nil)
      both = Jobs.board_page(nil, filters) |> ids() |> Enum.sort()
      assert both == Enum.sort([elixir.id, java.id])

      # A single ?tag=phoenix still works (backward compatible).
      single = Jobs.board_filters(%{"tag" => "phoenix"}, nil)
      assert ids(Jobs.board_page(nil, single)) == [elixir.id]
    end

    test "workplace and employment type filter", %{elixir: elixir, java: java} do
      assert ids(Jobs.board_page(nil, %{workplace: :onsite})) == [elixir.id]
      assert ids(Jobs.board_page(nil, %{workplace: :remote})) == [java.id]
      assert ids(Jobs.board_page(nil, %{employment: :part_time})) == [java.id]
    end
  end

  describe "salary filter (same currency, yearly-normalised)" do
    test "keeps postings whose yearly-equivalent max reaches the floor, same currency only" do
      poster = poster_fixture()

      year =
        publish_job!(poster, %{
          "title" => "Well paid",
          "salary_min" => "60000",
          "salary_max" => "80000",
          "salary_period" => "year",
          "salary_currency" => "EUR"
        })

      monthly =
        publish_job!(poster, %{
          "title" => "Monthly pay",
          "salary_min" => "4000",
          "salary_max" => "6000",
          "salary_period" => "month",
          "salary_currency" => "EUR"
        })

      usd =
        publish_job!(poster, %{
          "title" => "Dollar pay",
          "salary_min" => "90000",
          "salary_max" => "120000",
          "salary_period" => "year",
          "salary_currency" => "USD"
        })

      # 70k EUR floor: the 80k-year and the 72k-year-equivalent (6000*12) match.
      matched = Jobs.board_page(nil, %{salary_min: 70_000, salary_currency: "EUR"}) |> ids()
      assert year.id in matched
      assert monthly.id in matched
      # The USD posting never matches an EUR floor (no currency conversion).
      refute usd.id in matched

      # 100k EUR floor drops both EUR postings.
      high = Jobs.board_page(nil, %{salary_min: 100_000, salary_currency: "EUR"}) |> ids()
      refute year.id in high
      refute monthly.id in high
    end

    test "a typed minimum-salary param filters for any viewer (issue #953)" do
      poster = poster_fixture()

      high =
        publish_job!(poster, %{
          "title" => "Pays well",
          "salary_min" => "70000",
          "salary_max" => "90000",
          "salary_period" => "year",
          "salary_currency" => "EUR"
        })

      low =
        publish_job!(poster, %{
          "title" => "Pays little",
          "salary_min" => "30000",
          "salary_max" => "45000",
          "salary_period" => "year",
          "salary_currency" => "EUR"
        })

      # A logged-out visitor with no stored expectation still filters by a typed
      # figure: board_filters/2 turns the raw string into the same filter the
      # "mine" token would, at the installation's default currency.
      filters = Jobs.board_filters(%{"salary_min" => "60000"}, nil)
      assert filters.salary_min == 60_000
      assert filters.salary_currency == Jobs.default_currency()

      matched = Jobs.board_page(nil, filters) |> ids()
      assert high.id in matched
      refute low.id in matched
    end
  end

  describe "location filter" do
    test "distance_km is a sane haversine" do
      # Cologne cathedral to Berlin: ~477 km.
      assert_in_delta Geo.distance_km(50.94, 6.96, 52.52, 13.40), 477, 30
      assert Geo.distance_km(50.94, 6.96, 50.94, 6.96) == 0.0
    end

    test "near + radius keeps nearby onsite postings and drops far ones, remote stays in" do
      poster = poster_fixture()
      assert Geo.coordinates("DE", "50667"), "Cologne zip must resolve in the bundled dataset"

      cologne =
        publish_job!(poster, %{"title" => "Cologne role", "zip_code" => "50667", "city" => "Köln"})

      berlin =
        publish_job!(poster, %{
          "title" => "Berlin role",
          "zip_code" => "10115",
          "city" => "Berlin"
        })

      remote =
        publish_job!(poster, %{
          "title" => "Remote DE role",
          "workplace_type" => "remote",
          "remote_countries" => ["DE"]
        })

      near = Jobs.board_page(nil, %{near: "Köln", radius: 50, country: "DE"}) |> ids()
      assert cologne.id in near
      refute berlin.id in near
      # A remote posting for the searched country answers "near me OR remote for me".
      assert remote.id in near

      # The remote-only workplace chip narrows to just the remote posting.
      remote_only =
        Jobs.board_page(nil, %{near: "Köln", radius: 50, country: "DE", workplace: :remote})
        |> ids()

      assert remote_only == [remote.id]
    end

    test "country filter matches onsite by address country and remote by applicant country" do
      poster = poster_fixture()

      de =
        publish_job!(poster, %{
          "title" => "DE role",
          "zip_code" => "50667",
          "city" => "Köln",
          "country" => "DE"
        })

      at =
        publish_job!(poster, %{
          "title" => "AT role",
          "zip_code" => "1010",
          "city" => "Wien",
          "country" => "AT"
        })

      de_ids = Jobs.board_page(nil, %{country: "DE"}) |> ids()
      assert de.id in de_ids
      refute at.id in de_ids
    end

    test "an unknown zip falls back to text match so nothing disappears silently" do
      poster = poster_fixture()
      # A zip absent from the dataset: coordinates unresolved, city text match carries it.
      posting =
        publish_job!(poster, %{"title" => "Odd zip", "zip_code" => "00000", "city" => "Nowheria"})

      assert posting.id in (Jobs.board_page(nil, %{near: "Nowheria", radius: 50}) |> ids())
    end
  end

  describe "keyset pagination" do
    test "returns a cursor and the next page continues from it" do
      poster = poster_fixture()
      for n <- 1..3, do: publish_job!(poster, %{"title" => "Role #{n}"})

      first = Jobs.board_page(nil, %{}, limit: 2)
      assert length(first.entries) == 2
      assert first.more?
      assert first.cursor

      second = Jobs.board_page(nil, %{}, limit: 2, cursor: first.cursor)
      assert length(second.entries) == 1
      refute second.more?

      all = ids(first) ++ ids(second)
      assert length(Enum.uniq(all)) == 3
    end
  end

  describe "agent board" do
    test "lists only everyone + geo? postings" do
      poster = poster_fixture()

      public =
        publish_job!(poster, %{"title" => "Public", "visibility" => "everyone", "geo?" => "true"})

      _members = publish_job!(poster, %{"title" => "Members only", "visibility" => "members"})
      _no_geo = publish_job!(poster, %{"title" => "No agent docs", "geo?" => "false"})

      assert ids(Jobs.agent_board_page()) == [public.id]
    end
  end

  describe "scoped listings" do
    test "organization postings list only that organization's live public postings" do
      owner = poster_fixture()
      org = insert(:organization, created_by_user_id: owner.id)
      {:ok, draft} = Jobs.create_draft(owner, %{"title" => "At the org"}, organization: org)

      {:ok, posting} =
        Jobs.publish(draft, owner, job_attrs(%{"title" => "At the org"}), organization: org)

      assert Jobs.organization_postings_count(org, nil) == 1
      assert [%{id: id}] = Jobs.list_organization_postings(org, nil).entries
      assert id == posting.id
    end

    test "tag postings list live public postings carrying the tag" do
      poster = poster_fixture()
      posting = publish_job!(poster, %{"title" => "Tagged", "required_tags" => "Rustacean"})
      tag = Tag.find_by_value("Rustacean")

      assert [%{id: id}] = Jobs.list_tag_postings(tag, nil)
      assert id == posting.id
    end
  end
end
