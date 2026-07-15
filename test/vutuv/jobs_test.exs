defmodule Vutuv.JobsTest do
  use Vutuv.DataCase, async: true

  import Vutuv.JobsHelpers

  alias Vutuv.Jobs
  alias Vutuv.Jobs.JobPosting
  alias Vutuv.Repo

  describe "create_draft/3" do
    test "a minimal draft needs only a title" do
      user = poster_fixture()
      assert {:ok, %JobPosting{} = posting} = Jobs.create_draft(user, %{"title" => "Anything"})
      assert posting.status == :draft
      assert posting.user_id == user.id
      assert posting.slug =~ "anything"
    end

    test "a blank title is rejected" do
      user = poster_fixture()
      assert {:error, changeset} = Jobs.create_draft(user, %{"title" => "  "})
      assert "can't be blank" in errors_on(changeset).title
    end
  end

  describe "update image handling" do
    # Regression: an update whose attrs carry NO image_ids key (the jobs API
    # documents no image field, so an integrator's PATCH of just the title
    # never sends one) must leave the attached gallery alone — treating the
    # missing key as [] silently deleted every image.
    test "an update without an image_ids key leaves attached images alone" do
      user = poster_fixture()
      posting = publish_job!(user)
      image = insert(:job_posting_image, user: user, job_posting: posting)

      assert {:ok, _} = Jobs.update_posting(posting, user, %{"title" => "Renamed role"})

      assert Repo.get(Vutuv.Jobs.JobPostingImage, image.id).job_posting_id == posting.id
    end

    test "an update with an explicit image_ids list still prunes removed images" do
      user = poster_fixture()
      posting = publish_job!(user)
      keep = insert(:job_posting_image, user: user, job_posting: posting)
      drop = insert(:job_posting_image, user: user, job_posting: posting)

      assert {:ok, _} =
               Jobs.update_posting(posting, user, %{
                 "title" => "Renamed role",
                 "image_ids" => [keep.id]
               })

      assert Repo.get(Vutuv.Jobs.JobPostingImage, keep.id)
      refute Repo.get(Vutuv.Jobs.JobPostingImage, drop.id)
    end
  end

  describe "sweep_pending_images/1" do
    test "deletes abandoned pending uploads but keeps fresh and attached ones" do
      user = poster_fixture()
      posting = publish_job!(user)

      old = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -25 * 3600, :second)
      abandoned = insert(:job_posting_image, user: user, inserted_at: old)
      fresh = insert(:job_posting_image, user: user)
      attached = insert(:job_posting_image, user: user, job_posting: posting, inserted_at: old)

      assert Jobs.sweep_pending_images() == 1

      refute Repo.get(Vutuv.Jobs.JobPostingImage, abandoned.id)
      assert Repo.get(Vutuv.Jobs.JobPostingImage, fresh.id)
      assert Repo.get(Vutuv.Jobs.JobPostingImage, attached.id)
    end
  end

  describe "publish/3" do
    test "a full on-site posting publishes, resolves coordinates and sets a 90-day expiry" do
      user = poster_fixture()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      assert {:ok, posting} = Jobs.publish(draft, user, job_attrs())

      assert posting.status == :published
      assert posting.expires_on == Date.add(Vutuv.BerlinTime.today(), 90)
      assert posting.first_published_at
      # 50667 is central Cologne, so coordinates resolve offline.
      assert posting.lat && posting.lon
    end

    test "publishing without a salary range is rejected inline" do
      user = poster_fixture()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      attrs = job_attrs(%{"salary_min" => "", "salary_max" => ""})
      assert {:error, changeset} = Jobs.publish(draft, user, attrs)
      assert "can't be blank" in errors_on(changeset).salary_min
    end

    test "a volunteer posting publishes without a salary and clears the range" do
      user = poster_fixture()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})

      attrs =
        job_attrs(%{
          "employment_type" => "volunteer",
          "salary_min" => "",
          "salary_max" => ""
        })

      assert {:ok, posting} = Jobs.publish(draft, user, attrs)
      assert Jobs.JobPosting |> Repo.get(posting.id) |> Map.get(:salary_min) == nil
    end

    test "publishing without a location for an on-site posting is rejected" do
      user = poster_fixture()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      attrs = job_attrs(%{"zip_code" => "", "city" => "", "country" => ""})
      assert {:error, changeset} = Jobs.publish(draft, user, attrs)
      assert errors_on(changeset).city
    end

    test "a remote posting requires applicant countries and clears the address" do
      user = poster_fixture()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})

      no_countries =
        job_attrs(%{"workplace_type" => "remote", "remote_countries" => []})

      assert {:error, changeset} = Jobs.publish(draft, user, no_countries)
      assert errors_on(changeset).remote_countries

      {:ok, posting} =
        Jobs.publish(
          draft,
          user,
          job_attrs(%{
            "workplace_type" => "remote",
            "remote_countries" => ["DE", "AT"]
          })
        )

      assert posting.remote_countries == ["DE", "AT"]
      assert posting.city == nil
      assert posting.zip_code == nil
    end

    test "an unresolvable zip still publishes, just without coordinates" do
      user = poster_fixture()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      {:ok, posting} = Jobs.publish(draft, user, job_attrs(%{"zip_code" => "00000"}))
      assert posting.status == :published
      assert posting.lat == nil
    end
  end

  describe "anti-abuse gate" do
    test "an unconfirmed account may not publish" do
      user = insert(:user, email_confirmed?: false)
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      assert {:error, :email_unconfirmed} = Jobs.publish(draft, user, job_attrs())
    end

    test "a brand-new account may not publish" do
      user = insert(:activated_user)
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      assert {:error, :account_too_new} = Jobs.publish(draft, user, job_attrs())
    end

    test "the concurrent-publish cap blocks a fourth posting" do
      user = poster_fixture()

      for _ <- 1..Jobs.max_published_per_member() do
        {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
        {:ok, _} = Jobs.publish(draft, user, job_attrs())
      end

      {:ok, over} = Jobs.create_draft(user, %{"title" => "One too many"})
      assert {:error, :member_quota} = Jobs.publish(over, user, job_attrs())
    end

    test "postings past their expiry (not yet swept) do not occupy a cap slot" do
      user = poster_fixture()

      for _ <- 1..Jobs.max_published_per_member() do
        {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
        {:ok, _} = Jobs.publish(draft, user, job_attrs())
      end

      # Backdate every published posting past expiry without running the sweeper,
      # so status is still :published but effective_status is :expired.
      yesterday = Date.add(Vutuv.BerlinTime.today(), -1)

      Repo.update_all(
        from(p in JobPosting, where: p.user_id == ^user.id and p.status == :published),
        set: [expires_on: yesterday]
      )

      {:ok, fresh} = Jobs.create_draft(user, %{"title" => "New role"})
      assert {:ok, _} = Jobs.publish(fresh, user, job_attrs())
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
      user = poster_fixture()
      liker = insert(:activated_user)
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      {:ok, posting} = Jobs.publish(draft, user, job_attrs())

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
      user = poster_fixture()
      honor = insert(:tag, name: "CEO", honor?: true)

      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})

      {:ok, posting} =
        Jobs.publish(
          draft,
          user,
          job_attrs(%{
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
      user = poster_fixture()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      {:ok, posting} = Jobs.publish(draft, user, job_attrs(%{"required_tags" => "Elixir"}))

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
      user = poster_fixture()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      {:ok, posting} = Jobs.publish(draft, user, job_attrs())
      %{user: user, posting: posting, draft: draft}
    end

    test "a draft is owner-only", %{user: user, draft: draft} do
      assert Jobs.visible_to?(draft, user)
      refute Jobs.visible_to?(draft, insert(:activated_user))
      refute Jobs.visible_to?(draft, nil)
    end

    test "a members-only draft is still owner-only, not shown to signed-in members",
         %{user: user, draft: draft} do
      {:ok, members_draft} =
        draft
        |> Ecto.Changeset.change(visibility: :members)
        |> Repo.update()

      assert Jobs.visible_to?(members_draft, user)
      refute Jobs.visible_to?(members_draft, insert(:activated_user))
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
      user = poster_fixture()
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Draft"})
      {:ok, posting} = Jobs.publish(draft, user, job_attrs())

      yesterday = Date.add(Vutuv.BerlinTime.today(), -1)

      Repo.update_all(from(p in JobPosting, where: p.id == ^posting.id),
        set: [expires_on: yesterday]
      )

      assert Jobs.expire_overdue(Vutuv.BerlinTime.today()) == 1
      assert Repo.get(JobPosting, posting.id).status == :expired
    end
  end
end
