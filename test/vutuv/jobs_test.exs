defmodule Vutuv.JobsTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Jobs
  alias Vutuv.Jobs.JobPosting
  alias Vutuv.Repo

  # A confirmed account old enough to publish (the anti-abuse gate needs both).
  defp poster do
    user = insert(:activated_user)
    old = NaiveDateTime.add(NaiveDateTime.utc_now(), -5 * 86_400, :second)

    {1, _} =
      Repo.update_all(from(u in Vutuv.Accounts.User, where: u.id == ^user.id),
        set: [inserted_at: old]
      )

    Repo.reload!(user)
  end

  defp onsite_attrs(extra \\ %{}) do
    Map.merge(
      %{
        "title" => "Elixir Developer (m/w/d)",
        "employment_type" => "full_time",
        "workplace_type" => "onsite",
        "zip_code" => "50667",
        "city" => "Köln",
        "country" => "DE",
        "salary_min" => "50000",
        "salary_max" => "65000",
        "salary_currency" => "EUR",
        "salary_period" => "year",
        "apply_kind" => "message"
      },
      extra
    )
  end

  describe "create_draft/3" do
    test "a minimal draft needs only a title" do
      user = poster()
      assert {:ok, %JobPosting{} = posting} = Jobs.create_draft(user, %{"title" => "Anything"})
      assert posting.status == :draft
      assert posting.user_id == user.id
      assert posting.slug =~ "anything"
    end

    test "a blank title is rejected" do
      user = poster()
      assert {:error, changeset} = Jobs.create_draft(user, %{"title" => "  "})
      assert "can't be blank" in errors_on(changeset).title
    end
  end

  describe "publish/3" do
    test "a full on-site posting publishes, resolves coordinates and sets a 90-day expiry" do
      user = poster()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      assert {:ok, posting} = Jobs.publish(draft, user, onsite_attrs())

      assert posting.status == :published
      assert posting.expires_on == Date.add(Vutuv.BerlinTime.today(), 90)
      assert posting.first_published_at
      # 50667 is central Cologne, so coordinates resolve offline.
      assert posting.lat && posting.lon
    end

    test "publishing without a salary range is rejected inline" do
      user = poster()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      attrs = onsite_attrs(%{"salary_min" => "", "salary_max" => ""})
      assert {:error, changeset} = Jobs.publish(draft, user, attrs)
      assert "can't be blank" in errors_on(changeset).salary_min
    end

    test "a volunteer posting publishes without a salary and clears the range" do
      user = poster()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})

      attrs =
        onsite_attrs(%{
          "employment_type" => "volunteer",
          "salary_min" => "",
          "salary_max" => ""
        })

      assert {:ok, posting} = Jobs.publish(draft, user, attrs)
      assert Jobs.JobPosting |> Repo.get(posting.id) |> Map.get(:salary_min) == nil
    end

    test "publishing without a location for an on-site posting is rejected" do
      user = poster()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      attrs = onsite_attrs(%{"zip_code" => "", "city" => "", "country" => ""})
      assert {:error, changeset} = Jobs.publish(draft, user, attrs)
      assert errors_on(changeset).city
    end

    test "a remote posting requires applicant countries and clears the address" do
      user = poster()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})

      no_countries =
        onsite_attrs(%{"workplace_type" => "remote", "remote_countries" => []})

      assert {:error, changeset} = Jobs.publish(draft, user, no_countries)
      assert errors_on(changeset).remote_countries

      {:ok, posting} =
        Jobs.publish(
          draft,
          user,
          onsite_attrs(%{
            "workplace_type" => "remote",
            "remote_countries" => ["DE", "AT"]
          })
        )

      assert posting.remote_countries == ["DE", "AT"]
      assert posting.city == nil
      assert posting.zip_code == nil
    end

    test "an unresolvable zip still publishes, just without coordinates" do
      user = poster()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      {:ok, posting} = Jobs.publish(draft, user, onsite_attrs(%{"zip_code" => "00000"}))
      assert posting.status == :published
      assert posting.lat == nil
    end
  end

  describe "anti-abuse gate" do
    test "an unconfirmed account may not publish" do
      user = insert(:user, email_confirmed?: false)
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      assert {:error, :email_unconfirmed} = Jobs.publish(draft, user, onsite_attrs())
    end

    test "a brand-new account may not publish" do
      user = insert(:activated_user)
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      assert {:error, :account_too_new} = Jobs.publish(draft, user, onsite_attrs())
    end

    test "the concurrent-publish cap blocks a fourth posting" do
      user = poster()

      for _ <- 1..Jobs.max_published_per_member() do
        {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
        {:ok, _} = Jobs.publish(draft, user, onsite_attrs())
      end

      {:ok, over} = Jobs.create_draft(user, %{"title" => "One too many"})
      assert {:error, :member_quota} = Jobs.publish(over, user, onsite_attrs())
    end
  end

  describe "AGG title hint" do
    test "fires when no neutral gender marker is present" do
      assert JobPosting.agg_hint?("Softwareentwickler")
      assert JobPosting.agg_hint?("Developer (m/w)")
      assert JobPosting.agg_hint?("Developer (m)")
    end

    test "is silent when a documented marker is present" do
      refute JobPosting.agg_hint?("Developer (m/w/d)")
      refute JobPosting.agg_hint?("Developer (w/m/d)")
      refute JobPosting.agg_hint?("Developer (m/w/x)")
      refute JobPosting.agg_hint?("Entwickler*innen")
      refute JobPosting.agg_hint?("Team lead (all genders)")
    end
  end

  describe "engagement" do
    test "like is idempotent and counted; unlike removes it" do
      user = poster()
      liker = insert(:activated_user)
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      {:ok, posting} = Jobs.publish(draft, user, onsite_attrs())

      {:ok, _} = Jobs.like_job_posting(liker, posting)
      {:ok, :noop} = Jobs.like_job_posting(liker, posting)
      assert Jobs.job_posting_engagement(posting, liker).likes == 1
      assert Jobs.job_posting_engagement(posting, liker).liked?

      :ok = Jobs.unlike_job_posting(liker, posting)
      assert Jobs.job_posting_engagement(posting, liker).likes == 0
    end
  end

  describe "tags" do
    test "required and nice-to-have tags attach with priority; honor tags are excluded" do
      user = poster()
      honor = insert(:tag, name: "CEO", honor?: true)

      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})

      {:ok, posting} =
        Jobs.publish(
          draft,
          user,
          onsite_attrs(%{
            "required_tags" => "Elixir, Phoenix",
            "nice_to_have_tags" => "Kubernetes, CEO"
          })
        )

      posting = Jobs.preload_for_show(posting)

      assert Enum.map(Jobs.tags_of(posting, :required), & &1.name) |> Enum.sort() == [
               "Elixir",
               "Phoenix"
             ]

      nice = Enum.map(Jobs.tags_of(posting, :nice_to_have), & &1.name)
      assert "Kubernetes" in nice
      refute honor.name in nice
    end
  end

  describe "repost/2" do
    test "clones an expired posting as a fresh draft with a new slug" do
      user = poster()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      {:ok, posting} = Jobs.publish(draft, user, onsite_attrs(%{"required_tags" => "Elixir"}))

      assert {:ok, clone} = Jobs.repost(posting, user)
      assert clone.status == :draft
      assert clone.id != posting.id
      assert clone.slug != posting.slug
      assert clone.title == posting.title
      assert Enum.map(Jobs.tags_of(clone, :required), & &1.name) == ["Elixir"]
    end
  end

  describe "visibility" do
    setup do
      user = poster()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      {:ok, posting} = Jobs.publish(draft, user, onsite_attrs())
      %{user: user, posting: posting, draft: draft}
    end

    test "a draft is owner-only", %{user: user, draft: draft} do
      assert Jobs.visible_to?(draft, user)
      refute Jobs.visible_to?(draft, insert(:activated_user))
      refute Jobs.visible_to?(draft, nil)
    end

    test "a published everyone posting is visible to anyone", %{posting: posting} do
      assert Jobs.visible_to?(posting, nil)
      assert Jobs.indexable?(posting)
      assert Jobs.agent_visible?(posting)
    end

    test "a members-only posting hides from anonymous viewers", %{posting: posting} do
      {:ok, members_only} =
        posting
        |> JobPosting.status_changeset(:published)
        |> Ecto.Changeset.put_change(:visibility, :members)
        |> Repo.update()

      refute Jobs.visible_to?(members_only, nil)
      assert Jobs.visible_to?(members_only, insert(:activated_user))
      refute Jobs.indexable?(members_only)
    end
  end

  describe "expire_overdue/1" do
    test "flips a posting whose expiry has passed to expired" do
      user = poster()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      {:ok, posting} = Jobs.publish(draft, user, onsite_attrs())

      yesterday = Date.add(Vutuv.BerlinTime.today(), -1)

      Repo.update_all(from(p in JobPosting, where: p.id == ^posting.id),
        set: [expires_on: yesterday]
      )

      assert Jobs.expire_overdue(Vutuv.BerlinTime.today()) == 1
      assert Repo.get(JobPosting, posting.id).status == :expired
    end
  end
end
