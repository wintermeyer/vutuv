defmodule Vutuv.ReportsTest do
  @moduledoc """
  The basic daily activity report: confirmed-by-PIN new registrations and the
  posts, reposts, likes and bookmarks created on one German calendar day, plus
  the overnight email that skips all-zero days.
  """
  use Vutuv.DataCase, async: false

  import Swoosh.TestAssertions

  alias Vutuv.Reports
  alias Vutuv.Reports.DailyReport

  # A winter day, so the Berlin offset is a flat +1h and the UTC bounds are
  # easy to reason about: [2026-01-14 23:00, 2026-01-15 23:00).
  @date ~D[2026-01-15]
  @on_day ~N[2026-01-15 12:00:00]
  @other_day ~N[2026-01-20 12:00:00]

  defp at(naive), do: [inserted_at: naive, updated_at: naive]

  defp like(post, user, naive) do
    Repo.insert!(struct(Vutuv.Posts.PostLike, [post_id: post.id, user_id: user.id] ++ at(naive)))
  end

  defp bookmark(post, user, naive) do
    Repo.insert!(
      struct(Vutuv.Posts.PostBookmark, [post_id: post.id, user_id: user.id] ++ at(naive))
    )
  end

  defp repost(post, user, naive) do
    Repo.insert!(
      struct(Vutuv.Posts.PostRepost, [post_id: post.id, user_id: user.id] ++ at(naive))
    )
  end

  describe "daily/1" do
    test "tallies each metric for the Berlin day, ignoring other days and unconfirmed sign-ups" do
      # Registrations: two PIN-confirmed on the day count; the unconfirmed
      # sign-up and the confirmed one a different day do not.
      insert(:activated_user, at(@on_day))
      insert(:activated_user, at(@on_day))
      insert(:user, [email_confirmed?: false] ++ at(@on_day))
      insert(:activated_user, at(@other_day))

      author = insert(:user)
      post = insert(:post, [user: author] ++ at(@on_day))
      insert(:post, [user: author] ++ at(@on_day))
      insert(:post, [user: author] ++ at(@other_day))

      reposter = insert(:user)
      repost(post, reposter, @on_day)
      repost(post, insert(:user), @other_day)

      like(post, insert(:user), @on_day)
      bookmark(post, insert(:user), @on_day)

      assert Reports.daily(@date) == %DailyReport{
               date: @date,
               registrations: 2,
               posts: 2,
               reposts: 1,
               likes: 1,
               bookmarks: 1
             }
    end

    test "counts new Fediverse followers gained that Berlin day" do
      user = insert(:user)

      for naive <- [@on_day, @on_day, @other_day] do
        Repo.insert!(
          struct(
            Vutuv.Fediverse.Follower,
            [
              user_id: user.id,
              actor_uri: "https://social.example/users/#{System.unique_integer([:positive])}",
              inbox_uri: "https://social.example/inbox"
            ] ++ at(naive)
          )
        )
      end

      assert Reports.daily(@date).fediverse_followers == 2
    end

    test "the day range is half-open: the start instant counts, the end instant does not" do
      author = insert(:user)
      # day_start = 2026-01-14 23:00 UTC (inclusive), day_end = 2026-01-15 23:00 (exclusive).
      insert(:post, [user: author] ++ at(~N[2026-01-14 23:00:00]))
      insert(:post, [user: author] ++ at(~N[2026-01-15 23:00:00]))

      assert Reports.daily(@date).posts == 1
    end

    test "an empty day is all zeros" do
      report = Reports.daily(@date)
      assert DailyReport.all_zero?(report)
      assert DailyReport.total(report) == 0
    end
  end

  describe "deliver_daily_email/1" do
    test "mails the operator a German report when the day had activity" do
      insert(:post, at(@on_day))

      assert {:ok, report} = Reports.deliver_daily_email(@date)
      assert report.posts == 1

      assert_email_sent(fn email ->
        assert {"Stefan Wintermeyer", "sw@wintermeyer-consulting.de"} = hd(email.to)
        assert email.subject =~ "Tagesbericht"
        assert email.subject =~ "15.01.2026"
        # The subject now carries the non-zero number(s).
        assert email.subject =~ "1 Beitrag"
        assert email.text_body =~ "Neue Beiträge"
        assert email.text_body =~ "Fediverse-Follower"
        assert email.text_body =~ "Zustellbarkeit"
        assert email.text_body =~ "admin/reports?date=2026-01-15"
      end)
    end

    test "skips an all-zero day, sending nothing" do
      assert Reports.deliver_daily_email(@date) == :skipped
      assert_no_email_sent()
    end
  end

  describe "deliverability metrics" do
    test "daily/1 tallies bounces and deactivation/freeze/thaw events for the Berlin day" do
      insert(:email_bounce, inserted_at: @on_day)
      insert(:email_bounce, inserted_at: @on_day)
      insert(:email_bounce, inserted_at: @other_day)
      insert(:deliverability_event, action: "address_deactivated", inserted_at: @on_day)
      insert(:deliverability_event, action: "account_frozen", inserted_at: @on_day)
      insert(:deliverability_event, action: "account_thawed", inserted_at: @on_day)
      insert(:deliverability_event, action: "account_frozen", inserted_at: @other_day)

      report = Reports.daily(@date)
      assert report.bounces == 2
      assert report.deactivations == 1
      assert report.freezes == 1
      assert report.thaws == 1
    end

    test "a day with only deliverability events still counts as activity (gets mailed)" do
      insert(:deliverability_event, action: "account_frozen", inserted_at: @on_day)
      refute DailyReport.all_zero?(Reports.daily(@date))
    end
  end

  describe "moderation removals" do
    test "counts accounts removed as spam that Berlin day, ignoring other days" do
      owner = insert(:user)

      case_record =
        Repo.insert!(%Vutuv.Moderation.Case{
          content_type: "user",
          content_id: owner.id,
          owner_id: owner.id,
          status: "upheld"
        })

      for naive <- [@on_day, @other_day] do
        Repo.insert!(
          struct(Vutuv.Moderation.Event,
            case_id: case_record.id,
            action: "owner_removed",
            detail: %{"action" => "deactivate", "reason" => "spam"},
            inserted_at: naive
          )
        )
      end

      report = Reports.daily(@date)
      assert report.spam_removals == 1
      refute DailyReport.all_zero?(report)
    end
  end

  describe "email_subject/1" do
    test "lists only the non-zero metrics, with singular/plural German labels" do
      report = %DailyReport{date: @date, registrations: 1, posts: 3, freezes: 1}

      assert DailyReport.email_subject(report) ==
               "vutuv Tagesbericht 15.01.2026: 1 Registrierung, 3 Beiträge, 1 eingefrorenes Konto"
    end

    test "omits the zero metrics entirely" do
      report = %DailyReport{date: @date, bounces: 2}
      assert DailyReport.email_subject(report) == "vutuv Tagesbericht 15.01.2026: 2 Bounces"
    end
  end
end
