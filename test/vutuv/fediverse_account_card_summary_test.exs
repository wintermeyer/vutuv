defmodule Vutuv.FediverseAccountCardSummaryTest do
  @moduledoc """
  What the mention card is allowed to say about an account beyond its own words:
  how many of its posts this installation holds *for this reader*, when the
  newest of them arrived, and the newest few themselves
  (`Vutuv.Fediverse.account_card_summary/2`).

  The interesting half is "for this reader". The count sits on a card that opens
  from a word in a sentence, so it is read as a fact about the account — which
  makes it exactly the kind of number that must not be built from rows the
  reader may not see. It answers with the same audience rule the account page's
  list uses, because one of them widening the other's audience is a leak that
  reads as a feature.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow

  defp follow(user, account, state) do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      follow_activity_id: "https://vutuv.test/activities/#{System.unique_integer([:positive])}",
      state: state
    })
  end

  test "it counts the open posts and hands back the newest of them" do
    user = federating_member()
    account = remote_account()

    cached_post(account,
      content_text: "Der ältere.",
      published_at: DateTime.add(DateTime.utc_now(:second), -3600)
    )

    newest = cached_post(account, content_text: "Der neueste.")

    assert %{count: 2, posts: [latest, older]} = Fediverse.account_card_summary(account, user)
    assert latest.id == newest.id
    assert older.content_text == "Der ältere."
  end

  # More than one, newest first, for the card's expander — and never more than
  # the card can use, however much the account has written.
  test "it hands back the newest few, newest first, capped" do
    user = federating_member()
    account = remote_account()
    now = DateTime.utc_now(:second)

    for hours <- 1..12 do
      cached_post(account,
        content_text: "Nummer #{hours}.",
        published_at: DateTime.add(now, -hours * 3600)
      )
    end

    assert %{count: 12, posts: posts} = Fediverse.account_card_summary(account, user)
    assert length(posts) < 12
    assert Enum.map(posts, & &1.content_text) |> Enum.take(2) == ["Nummer 1.", "Nummer 2."]
  end

  # The clock on the count line is the account's last word here, and not the
  # last word the card ends up quoting: the gates that drop a quote (a content
  # warning, the reader's own filters, the post they are already reading) must
  # not make an account that posted a minute ago look silent.
  test "the timestamp is the newest post's, quotable or not" do
    user = federating_member()
    account = remote_account()

    newest = cached_post(account, content_text: "Nicht für jeden.", sensitive: true)

    assert %{count: 1, last_at: last_at} = Fediverse.account_card_summary(account, user)
    assert last_at == newest.published_at
  end

  test "an account we hold nothing from answers zero and no post" do
    assert %{count: 0, last_at: nil, posts: []} =
             Fediverse.account_card_summary(remote_account(), federating_member())
  end

  # The calibration case. Take the audience clause out of
  # `account_card_summary/2` and this goes red: without it the count says 2 and
  # the preview line quotes a followers-only post at somebody who does not
  # follow the account.
  test "a followers-only post is invisible to a reader who does not follow" do
    stranger = federating_member()
    follower = federating_member()
    account = remote_account()

    cached_post(account, content_text: "Für alle.")
    restricted = cached_post(account, content_text: "Nur für Follower.", audience: "followers")

    assert %{count: 1, posts: [latest]} = Fediverse.account_card_summary(account, stranger)
    assert latest.content_text == "Für alle."

    follow(follower, account, "accepted")

    assert %{count: 2, posts: [seen | _]} = Fediverse.account_card_summary(account, follower)
    assert seen.id == restricted.id
  end

  # A follow the other server has not answered yet is not a follow: a pending
  # request must not open the author's followers-only posts.
  test "a follow still waiting for an answer opens nothing" do
    user = federating_member()
    account = remote_account()

    follow(user, account, "requested")
    cached_post(account, content_text: "Nur für Follower.", audience: "followers")

    assert %{count: 0, posts: []} = Fediverse.account_card_summary(account, user)
  end

  # A nil identity must answer "no accepted follow" rather than raise on a nil
  # comparison. It still sees the open posts — the guard only closes the
  # followers-only arm — so the account has to hold one of each, or the case
  # passes on an empty table and would keep passing with the guard deleted.
  test "nobody in particular sees the open posts and no more" do
    account = remote_account()

    cached_post(account, content_text: "Für alle.")
    cached_post(account, content_text: "Nur für Follower.", audience: "followers")

    assert %{count: 1, posts: [latest]} = Fediverse.account_card_summary(account, nil)
    assert latest.content_text == "Für alle."
  end
end
