defmodule Vutuv.DirectoryTest do
  @moduledoc """
  The member directory (`Vutuv.Directory`): the listed member set grouped
  alphabetically. The grouping key is the last name (first name as fallback),
  accents folded so Ö sorts under O (DIN 5007), everything that doesn't start
  with a letter in the shared "other" bucket. Unconfirmed and moderation-hidden
  members never appear.

  The two sets this module holds apart are `listed_users/0`, what the directory
  shows, and `indexable_users/0`, the narrower crawlable set the sitemap
  advertises. A member who opted out of search engines is in the first and not
  the second — before v7.407.0 the directory used the second for both, which hid
  them from a page whose whole job is to help somebody find them.
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

  test "unconfirmed and moderation-hidden members are excluded" do
    insert_activated_user(last_name: "Visible")
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

  test "a member who opted out of search engines is listed but not crawlable" do
    insert_activated_user(last_name: "Nachbar")
    insert_activated_user(last_name: "Nachbarin", noindex?: true)

    # The directory lists both; only the sitemap's set drops the opted-out one.
    assert counts_by_letter()["n"] == 2

    assert %{users: users, total: 2} = Directory.members_page("n", %{})
    assert Enum.map(users, & &1.last_name) == ["Nachbar", "Nachbarin"]

    assert Directory.indexable_users()
           |> Vutuv.Repo.all()
           |> Enum.map(& &1.last_name) == ["Nachbar"]
  end

  test "unreachable (every-email-bounced) members are excluded, like the withheld profile" do
    # unreachable_at hides the profile (Moderation.account_hidden?/1); the
    # crawlable set must agree, or a zombie account leaks into the directory and
    # sitemap while its profile is withheld (a 403 since issue #812).
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

  describe "search/3" do
    setup do
      insert_activated_user(first_name: "Anna", last_name: "Meier", username: "annadirsearch")
      insert_activated_user(first_name: "Meier", last_name: "Bosch", username: "boschdirsearch")
      insert_activated_user(first_name: "Carla", last_name: "Bosch", username: "meierdirsearch")
      :ok
    end

    defp found(query, fields \\ Directory.search_fields()) do
      case Directory.search(query, fields) do
        nil -> nil
        %{users: users} -> Enum.map(users, & &1.username) |> Enum.sort()
      end
    end

    test "ORs across the selected fields rather than ANDing them" do
      # One member per field carries "meier". All three come back together;
      # an AND would return none of them.
      assert found("meier") == ~w(annadirsearch boschdirsearch meierdirsearch)
    end

    test "each field can be searched on its own" do
      assert found("meier", [:last_name]) == ~w(annadirsearch)
      assert found("meier", [:first_name]) == ~w(boschdirsearch)
      assert found("meier", [:username]) == ~w(meierdirsearch)
    end

    test "an empty field list looks everywhere rather than nowhere" do
      # The last checkbox turned off arrives here as no field at all, and a
      # search that can find nobody would be the worst reading of it.
      assert found("meier", []) == ~w(annadirsearch boschdirsearch meierdirsearch)
    end

    test "every word of a multi-word query has to match some selected field" do
      # "anna mei" is the most natural thing to type into a box that says it
      # searches names, and no single-column match can answer it: "anna" is a
      # first name and "mei" a last one. Order does not matter, which a
      # first-then-last concatenation could never manage.
      assert found("anna mei") == ~w(annadirsearch)
      assert found("mei anna") == ~w(annadirsearch)

      # Both words still have to land inside the ticked fields.
      assert found("anna mei", [:last_name]) == []
      assert found("anna bosch") == []
    end

    test "answers nil below the minimum instead of the whole membership" do
      assert Directory.search("me") == nil
      assert Directory.search(" ") == nil
      assert Directory.search(nil) == nil
      assert Directory.search("mei") != nil
    end

    test "a typed LIKE wildcard matches itself" do
      # Unescaped, `%%%` would match every member and `_eier` every Meier.
      assert found("%%%") == []
      assert found("_eier") == []
    end

    test "total counts every match, users only the bite that is rendered" do
      assert %{users: [_one], total: 3} = Directory.search("meier", Directory.search_fields(), 1)
    end

    test "parse_search_fields reads the param through an allowlist" do
      assert Directory.parse_search_fields(["last_name"]) == [:last_name]
      assert Directory.parse_search_fields(["username", "first_name"]) == [:first_name, :username]

      # Anything not on the list is dropped, and a request left with nothing
      # falls back to all three rather than to none.
      assert Directory.parse_search_fields(["email", "password"]) == Directory.search_fields()
      assert Directory.parse_search_fields([]) == Directory.search_fields()
      assert Directory.parse_search_fields(nil) == Directory.search_fields()
      assert Directory.parse_search_fields([%{}, 5]) == Directory.search_fields()
    end
  end

  defp counts_by_letter do
    Map.new(Directory.letter_entries(), &{&1.letter, &1.count})
  end
end
