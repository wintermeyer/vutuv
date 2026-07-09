defmodule Vutuv.DirectoryTest do
  @moduledoc """
  The member directory (`Vutuv.Directory`): the crawlable member set grouped
  alphabetically. The grouping key is the last name (first name as fallback),
  accents folded so Ö sorts under O (DIN 5007), everything that doesn't start
  with a letter in the shared "other" bucket. Members who opted out of search
  engines (`noindex?`), are unconfirmed, or are moderation-hidden never appear.
  """

  use Vutuv.DataCase, async: true

  alias Vutuv.Directory

  test "letter_entries covers a-z plus other, in order" do
    letters = Enum.map(Directory.letter_entries(), & &1.letter)

    assert letters == Enum.map(?a..?z, &<<&1>>) ++ ["other"]
  end

  test "members are bucketed by last name, first name only as fallback" do
    insert_activated_user(first_name: "Anna", last_name: "Zabel")
    insert_activated_user(first_name: "Zoe", last_name: "Adler")
    # no last name: the first name decides
    insert_activated_user(first_name: "Bert", last_name: nil)
    # whitespace-only last name counts as absent
    insert_activated_user(first_name: "Carla", last_name: "  ")

    counts = counts_by_letter()

    assert counts["z"] == 1
    assert counts["a"] == 1
    assert counts["b"] == 1
    assert counts["c"] == 1
  end

  test "umlauts and accents fold into their base letter" do
    insert_activated_user(first_name: "Mesut", last_name: "Özil")
    insert_activated_user(first_name: "René", last_name: "Éluard")

    counts = counts_by_letter()

    assert counts["o"] == 1
    assert counts["e"] == 1
  end

  test "names that don't start with a letter land in the other bucket" do
    insert_activated_user(first_name: "DJ", last_name: "23skidoo")
    insert_activated_user(first_name: nil, last_name: nil)

    assert counts_by_letter()["other"] == 2
  end

  test "opted-out, unconfirmed and moderation-hidden members are excluded" do
    insert_activated_user(last_name: "Visible")
    insert_activated_user(last_name: "Vanished", noindex?: true)
    insert(:user, last_name: "Vague")
    insert_activated_user(last_name: "Verboten", frozen_at: ~N[2026-01-01 00:00:00])
    insert_activated_user(last_name: "Vergangen", deactivated_at: ~N[2026-01-01 00:00:00])

    insert_activated_user(
      last_name: "Verbannt",
      suspended_until: NaiveDateTime.add(NaiveDateTime.utc_now(), 3600)
    )

    assert counts_by_letter()["v"] == 1

    %{users: users} = Directory.members_page("v", %{})
    assert Enum.map(users, & &1.last_name) == ["Visible"]
  end

  test "unreachable (every-email-bounced) members are excluded, like the profile 404s" do
    # unreachable_at hides the profile (Moderation.account_hidden?/1); the
    # crawlable set must agree, or a zombie account leaks into the directory and
    # sitemap while its profile 404s.
    insert_activated_user(last_name: "Reachable")
    insert_activated_user(last_name: "Unreachable", unreachable_at: ~N[2026-01-01 00:00:00])

    assert counts_by_letter()["r"] == 1
    assert counts_by_letter()["u"] == 0

    assert %{users: [%{last_name: "Reachable"}], total: 1} = Directory.members_page("r", %{})
    assert %{users: [], total: 0} = Directory.members_page("u", %{})
  end

  test "members_page sorts by last name, then first name" do
    insert_activated_user(first_name: "Zoe", last_name: "Meyer")
    insert_activated_user(first_name: "Anna", last_name: "Meyer")
    insert_activated_user(first_name: "Jonas", last_name: "Maler")

    %{users: users, total: total} = Directory.members_page("m", %{})

    assert total == 3

    assert Enum.map(users, &{&1.last_name, &1.first_name}) ==
             [{"Maler", "Jonas"}, {"Meyer", "Anna"}, {"Meyer", "Zoe"}]
  end

  test "members_page for the other bucket" do
    insert_activated_user(first_name: "DJ", last_name: "23skidoo")
    insert_activated_user(first_name: "Ono", last_name: "Normal")

    %{users: users, total: 1} = Directory.members_page("other", %{})
    assert Enum.map(users, & &1.last_name) == ["23skidoo"]
  end

  test "valid_letter? accepts a-z and other, nothing else" do
    assert Directory.valid_letter?("a")
    assert Directory.valid_letter?("z")
    assert Directory.valid_letter?("other")
    refute Directory.valid_letter?("A")
    refute Directory.valid_letter?("aa")
    refute Directory.valid_letter?("1")
    refute Directory.valid_letter?("#")
    refute Directory.valid_letter?("")
  end

  test "total sums the letter entries" do
    insert_activated_user(last_name: "Adler")
    insert_activated_user(last_name: "Zabel")

    entries = Directory.letter_entries()
    assert Directory.total(entries) == 2
  end

  defp counts_by_letter do
    Map.new(Directory.letter_entries(), &{&1.letter, &1.count})
  end
end
