defmodule VutuvWeb.JobPostingTagControllerTest do
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.JobPostings.JobPostingTag

  # Job-posting tag writes (create/delete) must be gated exactly like the parent
  # JobPostingController writes: only the logged-in owner who holds a *paid*
  # recruiter subscription may add or remove tags. Before the fix this
  # controller had no authorization at all, so any anonymous visitor who knew a
  # job-posting slug could mutate its tags.

  # Give `user` a current, paid recruiter subscription so AuthRecruiter passes.
  defp paid_subscription(user) do
    package = insert(:recruiter_package)

    insert(:recruiter_subscription,
      user: user,
      recruiter_package: package,
      paid: true,
      subscription_begins: Date.add(Date.utc_today(), -1),
      subscription_ends: Date.add(Date.utc_today(), 365)
    )
  end

  describe "unauthenticated visitor" do
    setup %{conn: conn} do
      # Register the owner through the real flow so a resolvable Slug exists and
      # `UserResolveSlug` reaches the controller (the bare factory user has no
      # Slug row and would 404 before authorization ever runs).
      {:ok, owner} =
        Vutuv.Accounts.register_user(conn, %{
          "emails" => %{"0" => %{"value" => "owner@example.com"}},
          "first_name" => "Owner"
        })

      # A validated owner so the request clears `EnsureValidated` and the slug
      # resolves; the point is that authorization (AuthRecruiter) must still
      # reject the anonymous caller.
      owner =
        owner
        |> Ecto.Changeset.change(%{validated?: true})
        |> Repo.update!()

      job_posting = insert(:job_posting, user: owner)
      %{owner: owner, job_posting: job_posting}
    end

    test "cannot create a tag (403) and nothing is stored", %{
      conn: conn,
      owner: owner,
      job_posting: job_posting
    } do
      conn =
        post(conn, ~p"/users/#{owner}/job_postings/#{job_posting}/tags",
          job_posting_tag: %{"value" => "elixir", "priority" => 1}
        )

      assert conn.status == 403
      assert Repo.aggregate(JobPostingTag, :count) == 0
    end

    test "cannot delete an existing tag (403) and it is kept", %{
      conn: conn,
      owner: owner,
      job_posting: job_posting
    } do
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      jpt = insert(:job_posting_tag, job_posting: job_posting, tag: tag, priority: 1)

      conn =
        delete(conn, ~p"/users/#{owner}/job_postings/#{job_posting}/tags/#{tag.slug}")

      assert conn.status == 403
      assert Repo.get(JobPostingTag, jpt.id)
    end
  end

  describe "authorized owner (paid recruiter)" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      paid_subscription(user)
      job_posting = insert(:job_posting, user: user)
      %{conn: conn, user: user, job_posting: job_posting}
    end

    test "can create a tag", %{conn: conn, user: user, job_posting: job_posting} do
      conn =
        post(conn, ~p"/users/#{user}/job_postings/#{job_posting}/tags",
          job_posting_tag: %{"value" => "elixir", "priority" => 1}
        )

      assert redirected_to(conn) ==
               ~p"/users/#{user}/job_postings/#{job_posting}/tags"

      assert Repo.aggregate(JobPostingTag, :count) == 1
    end

    test "can delete a tag", %{conn: conn, user: user, job_posting: job_posting} do
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      jpt = insert(:job_posting_tag, job_posting: job_posting, tag: tag, priority: 1)

      conn =
        delete(conn, ~p"/users/#{user}/job_postings/#{job_posting}/tags/#{tag.slug}")

      assert redirected_to(conn) ==
               ~p"/users/#{user}/job_postings/#{job_posting}/tags"

      refute Repo.get(JobPostingTag, jpt.id)
    end

    test "cannot create a tag on another user's job posting (scoped to path user)",
         %{conn: conn, user: user} do
      # Attacker is a logged-in paid recruiter, but passes a victim's globally
      # unique job-posting slug under their own user slug. AuthRecruiter alone
      # only checks the path user, so the resolution must be scoped to the
      # path user to keep the recruiter off another user's posting.
      victim = insert(:user)
      victims_posting = insert(:job_posting, user: victim)

      conn =
        post(conn, ~p"/users/#{user}/job_postings/#{victims_posting}/tags",
          job_posting_tag: %{"value" => "elixir", "priority" => 1}
        )

      assert conn.status == 404
      assert Repo.aggregate(JobPostingTag, :count) == 0
    end
  end
end
