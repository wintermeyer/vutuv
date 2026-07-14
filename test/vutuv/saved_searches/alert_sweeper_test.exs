defmodule Vutuv.SavedSearches.AlertSweeperTest do
  use Vutuv.DataCase, async: true

  import Ecto.Query
  import Swoosh.TestAssertions
  import Vutuv.JobsHelpers

  alias Vutuv.Accounts.User
  alias Vutuv.BerlinTime
  alias Vutuv.Repo
  alias Vutuv.SavedSearches
  alias Vutuv.SavedSearches.AlertSweeper
  alias Vutuv.SavedSearches.SavedSearch

  # A member who can be mailed.
  defp mailable_member do
    user = insert(:activated_user)
    insert(:email, user: user)
    user
  end

  # Backdate a saved search's high-water mark so a just-created match counts as
  # new (avoids a same-second tie between the mark and the match's timestamp).
  defp backdate_baseline(search, days) do
    at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-days * 86_400, :second)
      |> NaiveDateTime.truncate(:second)

    Repo.update_all(from(s in SavedSearch, where: s.id == ^search.id),
      set: [last_notified_at: at]
    )

    search
  end

  defp save(user, attrs, days_ago \\ 1) do
    {:ok, search} = SavedSearches.create(user, attrs)
    backdate_baseline(search, days_ago)
    search
  end

  describe "jobs alerts" do
    test "mails one digest with a new matching Cologne posting, then never repeats it" do
      recipient = mailable_member()

      save(recipient, %{
        kind: :jobs,
        query: "near=Köln&radius=50&salary_min=60000",
        notify: :daily
      })

      posting =
        publish_job!(poster_fixture(), %{
          "title" => "Cologne Backend Role",
          "salary_max" => "70000"
        })

      assert AlertSweeper.sweep(BerlinTime.today()) == 1

      assert_email_sent(fn email ->
        assert email.text_body =~ "Cologne Backend Role"
        assert email.text_body =~ posting.slug
      end)

      # High-water advanced → a second sweep the same day is silent.
      assert AlertSweeper.sweep(BerlinTime.today()) == 0
      assert_no_email_sent()
    end

    test "stays silent about a posting below the salary floor" do
      recipient = mailable_member()
      save(recipient, %{kind: :jobs, query: "salary_min=60000", notify: :daily})

      publish_job!(poster_fixture(), %{
        "title" => "Underpaid role",
        "salary_min" => "30000",
        "salary_max" => "40000"
      })

      assert AlertSweeper.sweep(BerlinTime.today()) == 0
      assert_no_email_sent()
    end

    test "never mails a posting first published before the search's baseline" do
      recipient = mailable_member()
      # Publish first, then save with a baseline of now, so the posting is old.
      publish_job!(poster_fixture(), %{"title" => "Old role", "salary_max" => "70000"})
      SavedSearches.create(recipient, %{kind: :jobs, query: "salary_min=60000", notify: :daily})

      assert AlertSweeper.sweep(BerlinTime.today()) == 0
      assert_no_email_sent()
    end
  end

  describe "people alerts" do
    setup do
      recipient = mailable_member()

      candidate =
        insert(:activated_user, first_name: "Ada", last_name: "Elixir", username: "ada-dev")

      # Registered before the baseline, so only a status change makes them "new".
      backdate_inserted_at(candidate, 3)
      %{recipient: recipient, candidate: candidate}
    end

    test "mails a member who newly becomes looking for a status search", ctx do
      save(ctx.recipient, %{kind: :people, query: "q=status%3Alooking", notify: :daily})
      flip_status(ctx.candidate, "looking", "members")

      assert AlertSweeper.sweep(BerlinTime.today()) == 1
      assert_email_sent(fn email -> assert email.text_body =~ ctx.candidate.username end)
    end

    test "a hidden status never matches", ctx do
      save(ctx.recipient, %{kind: :people, query: "q=status%3Alooking", notify: :daily})
      flip_status(ctx.candidate, "looking", "hidden")

      assert AlertSweeper.sweep(BerlinTime.today()) == 0
      assert_no_email_sent()
    end

    test "a blocked member never appears in the alert", ctx do
      save(ctx.recipient, %{kind: :people, query: "q=status%3Alooking", notify: :daily})
      flip_status(ctx.candidate, "looking", "members")
      {:ok, _} = Vutuv.Social.block_user(ctx.recipient, ctx.candidate)

      assert AlertSweeper.sweep(BerlinTime.today()) == 0
      assert_no_email_sent()
    end

    test "a member's private salary expectation never rides along in the mail", ctx do
      save(ctx.recipient, %{kind: :people, query: "q=status%3Alooking", notify: :daily})

      ctx.candidate
      |> User.changeset(%{
        "employment_status" => "looking",
        "employment_status_visibility" => "members",
        "desired_salary_min" => "98765",
        "desired_salary_visibility" => "everyone"
      })
      |> Repo.update!()

      assert AlertSweeper.sweep(BerlinTime.today()) == 1

      assert_email_sent(fn email ->
        refute email.text_body =~ "98765"
        assert email.text_body =~ ctx.candidate.username
      end)
    end

    test "a disabled search is not swept", ctx do
      search = save(ctx.recipient, %{kind: :people, query: "q=status%3Alooking", notify: :daily})
      flip_status(ctx.candidate, "looking", "members")
      {:ok, _} = SavedSearches.disable(search)

      assert AlertSweeper.sweep(BerlinTime.today()) == 0
      assert_no_email_sent()
    end
  end

  describe "member-level opt-out" do
    test "a member who turned off saved-search emails gets no digest" do
      recipient = mailable_member()

      Repo.update_all(from(u in User, where: u.id == ^recipient.id),
        set: [saved_search_emails?: false]
      )

      save(recipient, %{kind: :jobs, query: "salary_min=60000", notify: :daily})
      publish_job!(poster_fixture(), %{"title" => "A role", "salary_max" => "70000"})

      assert AlertSweeper.sweep(BerlinTime.today()) == 0
      assert_no_email_sent()
    end
  end

  defp backdate_inserted_at(user, days) do
    at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-days * 86_400, :second)
      |> NaiveDateTime.truncate(:second)

    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [inserted_at: at])
  end

  defp flip_status(user, status, visibility) do
    user
    |> User.changeset(%{
      "employment_status" => status,
      "employment_status_visibility" => visibility
    })
    |> Repo.update!()
  end
end
