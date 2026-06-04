defmodule VutuvWeb.JobPostingControllerTest do
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.JobPostings.JobPosting

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

  describe "create" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      paid_subscription(user)
      %{conn: conn, user: user}
    end

    test "stores the path user's id even when job_posting[user_id] is smuggled",
         %{conn: conn, user: user} do
      other = insert(:user)

      conn =
        post(conn, ~p"/users/#{user}/job_postings",
          job_posting: %{
            "title" => "Smuggled Posting",
            "user_id" => other.id
          }
        )

      assert redirected_to(conn) == ~p"/users/#{user}/job_postings"

      posting = Repo.get_by!(JobPosting, title: "Smuggled Posting")
      # The owner is set via build_assoc, never from params: the smuggled
      # `other.id` must be ignored.
      assert posting.user_id == user.id
      refute posting.user_id == other.id
    end
  end
end
