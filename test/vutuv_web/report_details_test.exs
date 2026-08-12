defmodule VutuvWeb.ReportDetailsTest do
  @moduledoc """
  The daily report's shared detail normalization: `sections/1` and the plain
  text block both surfaces (email + admin page) render from.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Posts
  alias Vutuv.Reports
  alias Vutuv.Reports.DailyReport
  alias VutuvWeb.ReportDetails

  @date ~D[2026-01-15]
  @on_day ~N[2026-01-15 12:00:00]

  defp at(naive), do: [inserted_at: naive, updated_at: naive]

  defp section(report, key) do
    Enum.find(ReportDetails.sections(report), &(&1.key == key))
  end

  describe "sections/1" do
    test "a registration entry carries the name, @handle and profile path" do
      insert(
        :activated_user,
        [username: "alice", first_name: "Alice", last_name: "Adams"] ++ at(@on_day)
      )

      report = Reports.daily(@date)
      registrations = section(report, :registrations)

      assert registrations.count == 1
      assert registrations.more == 0

      assert registrations.entries == [
               %{primary: "Alice Adams", secondary: "@alice", path: "/alice"}
             ]
    end

    test "a post entry is the first line, the author @handle and the permalink" do
      author = insert(:user, username: "bob")
      post = insert(:post, [user: author, body: "First line\nSecond line"] ++ at(@on_day))

      # Asserted against `Posts.path/1`, not a hand-written path: this line used
      # to read `/posts/<id>`, which only `/api/2.0` serves, so the report and
      # its email linked nowhere — and the test agreed with the bug.
      assert section(Reports.daily(@date), :posts).entries == [
               %{primary: "First line", secondary: "@bob", path: Posts.path(post)}
             ]

      assert Posts.path(post) == "/bob/posts/#{post.id}"
    end

    test "a text-less (photo-only) post falls back to the author handle as the line" do
      author = insert(:user, username: "carol")
      post = insert(:post, [user: author, body: ""] ++ at(@on_day))

      assert section(Reports.daily(@date), :posts).entries == [
               %{primary: "@carol", secondary: nil, path: Posts.path(post)}
             ]
    end

    test "a page's post links under the organization permalink shape" do
      organization = insert(:organization)
      post = insert(:post, [user: nil, organization: organization, body: "Neu."] ++ at(@on_day))

      assert section(Reports.daily(@date), :posts).entries == [
               %{
                 primary: "Neu.",
                 secondary: organization.name,
                 path: "/organizations/#{organization.slug}/posts/#{post.id}"
               }
             ]
    end

    test "a pruned Fediverse follower names the server, not the person who left" do
      user = insert(:user, username: "dora")

      Repo.insert!(
        struct(
          Vutuv.Fediverse.FollowerPrune,
          [user_id: user.id, host: "social.example", status: 410] ++ at(@on_day)
        )
      )

      assert section(Reports.daily(@date), :fediverse_prunes).entries == [
               %{primary: "social.example", secondary: "HTTP 410 · @dora", path: "/dora"}
             ]
    end

    test "a bounce names the address and its status, with no link" do
      insert(:email_bounce,
        email_value: "dead@example.com",
        status: "5.1.1",
        inserted_at: @on_day
      )

      assert section(Reports.daily(@date), :bounces).entries == [
               %{primary: "dead@example.com", secondary: "5.1.1", path: nil}
             ]
    end

    test "more/1 reports how many rows were dropped past the cap" do
      author = insert(:user)
      over = DailyReport.detail_limit() + 2
      for _ <- 1..over, do: insert(:post, [user: author] ++ at(@on_day))

      posts = section(Reports.daily(@date), :posts)
      assert length(posts.entries) == DailyReport.detail_limit()
      assert posts.more == 2
    end

    test "a quiet day yields no sections" do
      assert ReportDetails.sections(Reports.daily(@date)) == []
    end
  end

  describe "text_block/2" do
    test "renders headings, entries and the resolved URL on its own line" do
      insert(
        :activated_user,
        [username: "alice", first_name: "Alice", last_name: "Adams"] ++ at(@on_day)
      )

      block = ReportDetails.text_block(Reports.daily(@date), "https://vutuv.de/")

      assert block =~ "Details"
      assert block =~ "Neue bestätigte Registrierungen (per PIN): 1"
      assert block =~ "- Alice Adams (@alice)"
      assert block =~ "https://vutuv.de/alice"
    end

    test "is empty on a quiet day" do
      assert ReportDetails.text_block(Reports.daily(@date), "https://vutuv.de/") == ""
    end
  end
end
