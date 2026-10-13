defmodule Vutuv.Moderation.LinkSpamTest do
  @moduledoc """
  The check that freezes a brand-new account registered to plant a link:
  one name, and a link that leaves the site in the headline.
  """
  use Vutuv.DataCase, async: true

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Moderation
  alias Vutuv.Moderation.AdminAction
  alias Vutuv.Moderation.LinkSpam
  alias Vutuv.Reports

  @headline "https://sexualitytest.example Sexuality Test: Explore"

  defp planted(attrs \\ []) do
    insert(
      :activated_user,
      Keyword.merge([first_name: "vbsvinwz", last_name: nil, headline: @headline], attrs)
    )
  end

  defp hours_ago(hours), do: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -hours * 3600)

  defp frozen?(%User{id: id}), do: Repo.get!(User, id).frozen_at != nil

  defp actions_for(%User{id: id}), do: Repo.all(from(a in AdminAction, where: a.user_id == ^id))

  test "freezes a new single-name account with a link in its headline and says why" do
    user = planted()

    assert LinkSpam.run() == 1

    assert frozen?(user)

    assert [%AdminAction{action: "account_frozen", actor_id: nil, detail: detail}] =
             actions_for(user)

    assert detail == %{"rule" => "new_account_link"}
  end

  test "a Markdown link and a last name alone are caught the same way" do
    user = planted(first_name: nil, last_name: "tqmnkhne", headline: "[ACE](https://ace.example)")

    assert LinkSpam.run() == 1
    assert frozen?(user)
  end

  test "leaves alone what the rule does not describe" do
    spared = [
      planted(last_name: "Hubert"),
      planted(headline: "Softwarearchäologe aus dem Sauerland"),
      planted(headline: nil),
      planted(inserted_at: hours_ago(26)),
      planted(admin?: true),
      planted(email_confirmed?: false)
    ]

    assert LinkSpam.run() == 0
    refute Enum.any?(spared, &frozen?/1)
  end

  test "an account an admin has thawed is not frozen a second time" do
    user = planted()
    assert LinkSpam.run() == 1

    admin = insert(:activated_user, admin?: true)
    {:ok, :unfrozen} = Moderation.admin_unfreeze_user(Repo.get!(User, user.id), admin, "real")

    assert LinkSpam.run() == 0
    refute frozen?(user)
  end

  test "the frozen list can tell an automatic freeze from an admin's" do
    automatic = planted()
    LinkSpam.run()

    by_hand = insert(:activated_user)
    {:ok, :frozen} = Moderation.admin_freeze_user(by_hand, insert(:activated_user, admin?: true))

    set = Moderation.auto_frozen_ids([automatic.id, by_hand.id])

    assert MapSet.member?(set, automatic.id)
    refute MapSet.member?(set, by_hand.id)
  end

  test "the daily report counts and names the account" do
    user = planted()
    LinkSpam.run()

    report = Reports.daily(Vutuv.BerlinTime.today())

    assert report.link_spam_freezes == 1
    assert [%{user: %User{id: id}}] = report.details.link_spam_freezes
    assert id == user.id

    assert [%{label: "Automatisch eingefrorene Konten", entries: [entry]}] =
             report
             |> VutuvWeb.ReportDetails.sections()
             |> Enum.filter(&(&1.key == :link_spam_freezes))

    assert entry.path == "/" <> user.username
  end
end
