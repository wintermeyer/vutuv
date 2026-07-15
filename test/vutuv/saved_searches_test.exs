defmodule Vutuv.SavedSearchesTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Accounts.User
  alias Vutuv.SavedSearches
  alias Vutuv.SavedSearches.SavedSearch

  setup do
    %{user: insert(:activated_user)}
  end

  describe "create/2" do
    test "saves a search and, for a notifying cadence, stamps the high-water mark", %{user: user} do
      assert {:ok, search} =
               SavedSearches.create(user, %{
                 kind: :jobs,
                 query: "q=elixir&near=Köln",
                 notify: :daily
               })

      assert search.kind == :jobs
      assert search.notify == :daily
      assert search.user_id == user.id
      # last_notified_at is set to now, so the first sweep only reports matches
      # newer than when alerts were enabled.
      assert search.last_notified_at != nil
    end

    test "a search saved with notify none has no high-water mark yet", %{user: user} do
      assert {:ok, search} = SavedSearches.create(user, %{kind: :people, query: "q=tag%3Aelixir"})
      assert search.notify == :none
      assert search.last_notified_at == nil
    end

    test "rejects an invalid kind", %{user: user} do
      assert {:error, changeset} = SavedSearches.create(user, %{kind: :bogus, query: "q=x"})
      assert %{kind: _} = errors_on(changeset)
    end

    test "enforces the per-member cap", %{user: user} do
      for n <- 1..SavedSearches.max_per_member() do
        assert {:ok, _} = SavedSearches.create(user, %{kind: :jobs, query: "q=#{n}"})
      end

      assert {:error, :quota} = SavedSearches.create(user, %{kind: :jobs, query: "q=over"})
    end

    test "the cap is per member, not global", %{user: user} do
      other = insert(:activated_user)

      for n <- 1..SavedSearches.max_per_member(),
          do: SavedSearches.create(user, %{kind: :jobs, query: "q=#{n}"})

      assert {:ok, _} = SavedSearches.create(other, %{kind: :jobs, query: "q=x"})
    end
  end

  describe "update_notify/2" do
    test "turning alerts on from none resets the high-water mark", %{user: user} do
      {:ok, search} = SavedSearches.create(user, %{kind: :jobs, query: "q=x", notify: :none})
      assert search.last_notified_at == nil

      assert {:ok, updated} = SavedSearches.update_notify(search, %{notify: :weekly})
      assert updated.notify == :weekly
      assert updated.last_notified_at != nil
    end

    test "switching between notifying cadences keeps the mark", %{user: user} do
      {:ok, search} = SavedSearches.create(user, %{kind: :jobs, query: "q=x", notify: :daily})
      mark = search.last_notified_at

      assert {:ok, updated} = SavedSearches.update_notify(search, %{notify: :weekly})
      assert updated.last_notified_at == mark
    end
  end

  describe "listing, deletion, ownership" do
    test "list_for_user returns the member's searches newest first", %{user: user} do
      {:ok, a} = SavedSearches.create(user, %{kind: :jobs, query: "q=a"})
      {:ok, b} = SavedSearches.create(user, %{kind: :people, query: "q=b"})

      ids = SavedSearches.list_for_user(user).entries |> Enum.map(& &1.id)
      assert ids == [b.id, a.id]
    end

    test "get_for_user is owner-scoped", %{user: user} do
      other = insert(:activated_user)
      {:ok, search} = SavedSearches.create(user, %{kind: :jobs, query: "q=a"})

      assert %SavedSearch{} = SavedSearches.get_for_user(user, search.id)
      assert SavedSearches.get_for_user(other, search.id) == nil
      assert SavedSearches.get_for_user(user, "not-a-uuid") == nil
    end

    test "delete removes the search", %{user: user} do
      {:ok, search} = SavedSearches.create(user, %{kind: :jobs, query: "q=a"})
      assert {:ok, _} = SavedSearches.delete(search)
      assert SavedSearches.get_for_user(user, search.id) == nil
    end

    test "disable switches a search to none", %{user: user} do
      {:ok, search} = SavedSearches.create(user, %{kind: :jobs, query: "q=a", notify: :daily})
      assert {:ok, disabled} = SavedSearches.disable(search)
      assert disabled.notify == :none
    end
  end

  describe "due_searches/1" do
    test "daily searches are always due; weekly only on the weekly weekday", %{user: user} do
      {:ok, _daily} = SavedSearches.create(user, %{kind: :jobs, query: "q=d", notify: :daily})
      {:ok, _weekly} = SavedSearches.create(user, %{kind: :jobs, query: "q=w", notify: :weekly})
      {:ok, _none} = SavedSearches.create(user, %{kind: :jobs, query: "q=n", notify: :none})

      # A Monday (weekly_weekday) → both daily and weekly are due.
      monday = next_weekday(SavedSearches.weekly_weekday())
      queries = SavedSearches.due_searches(monday) |> Enum.map(& &1.query) |> Enum.sort()
      assert queries == ["q=d", "q=w"]

      # A non-Monday → only the daily one.
      tuesday = Date.add(monday, 1)
      assert SavedSearches.due_searches(tuesday) |> Enum.map(& &1.query) == ["q=d"]
    end
  end

  describe "presentation" do
    test "results_url rebuilds the page URL with the stored filters" do
      jobs = build(:saved_search, kind: :jobs, query: "q=elixir&near=Köln")
      people = build(:saved_search, kind: :people, query: "q=tag%3Aelixir")

      assert SavedSearches.results_url(jobs) == "/jobs?q=elixir&near=Köln"
      assert SavedSearches.results_url(people) == "/search?q=tag%3Aelixir"
      assert SavedSearches.results_url(build(:saved_search, kind: :jobs, query: "")) == "/jobs"
    end

    test "people summary_segments come from the operators inside the stored q" do
      # /search stores its operators inside `q` (tag:/ort:/status:), not as
      # their own URL params — the summary must parse them out, not look for
      # `tag=`/`city=`/`status=` params that never exist for a people search.
      q = URI.encode_www_form("berlin tag:elixir status:open")
      search = build(:saved_search, kind: :people, query: "q=" <> q)

      segments = SavedSearches.summary_segments(search)

      assert "#elixir" in segments
      assert "berlin" in segments
      assert User.employment_status_label("open") in segments
      refute Enum.any?(segments, &(&1 =~ "tag:"))
    end

    test "summary_segments omits the salary figure" do
      search =
        build(:saved_search, kind: :jobs, query: "q=Elixir&near=Köln&radius=50&salary_min=60000")

      segments = SavedSearches.summary_segments(search)

      assert "Elixir" in segments
      assert "Köln (50 km)" in segments
      refute Enum.any?(segments, &(&1 =~ "60000"))
    end
  end

  # The next date on or after today whose ISO weekday is `weekday`.
  defp next_weekday(weekday) do
    today = Vutuv.BerlinTime.today()
    Date.add(today, rem(weekday - Date.day_of_week(today) + 7, 7))
  end
end
