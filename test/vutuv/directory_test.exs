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
  alias Vutuv.Profiles.WorkExperience

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

  describe "search/3 across CV entries" do
    setup do
      past = insert_activated_user(last_name: "Vergangen", username: "pastdirsearch")

      insert(:work_experience,
        user: past,
        title: "Developer",
        organization: "Siemens AG",
        start_year: 2012,
        end_month: 3,
        end_year: 2016
      )

      current = insert_activated_user(last_name: "Laufend", username: "currentdirsearch")

      insert(:work_experience,
        user: current,
        title: "Designer",
        organization: "Siemens Healthineers",
        start_year: 2020,
        end_month: nil,
        end_year: nil
      )

      student = insert_activated_user(last_name: "Student", username: "schooldirsearch")
      insert(:education, user: student, school: "Universität Bremen", degree: "Diplom")

      :ok
    end

    test "a job that ended years ago is as findable as a running one" do
      # The whole point of the field: the member left Siemens in 2016 and no
      # listing has shown that employer since.
      assert found("siemens", [:organization]) == ~w(currentdirsearch pastdirsearch)
      assert found("siemens ag", [:organization]) == ~w(pastdirsearch)
    end

    test "the school field finds the institution" do
      assert found("bremen", [:school]) == ~w(schooldirsearch)
    end

    test "the school field looks at the institution, not the degree" do
      # Deliberate scope (Stefan, 2026-09-14): the checkbox says "Schule & Uni",
      # so it searches the name of the place, never the degree or the subject.
      assert found("diplom", [:school]) == []
      assert found("computer science", [:school]) == []
    end

    test "the two CV fields stay apart, and the name fields stay out of both" do
      assert found("siemens", [:school]) == []
      assert found("bremen", [:organization]) == []
      assert found("siemens", [:first_name, :last_name, :username]) == []
      assert found("vergangen", [:organization, :school]) == []
    end

    test "the name of a linked organization page matches too" do
      # The member typed "DB", the page is called "Deutsche Bahn AG": without
      # the join, a search for the real name finds nobody.
      member = insert_activated_user(last_name: "Bahner", username: "linkeddirsearch")
      organization = insert(:organization, name: "Deutsche Bahn AG")

      insert(:work_experience,
        user: member,
        organization: "DB Netz",
        organization_page: organization
      )

      # Both arms of the OR: the page's name and the member's own text.
      assert found("deutsche bahn", [:organization]) == ~w(linkeddirsearch)
      assert found("netz", [:organization]) == ~w(linkeddirsearch)
    end

    test "a page that is not public never makes a member findable" do
      # A pending claim or a frozen page shows its name nowhere, so it must not
      # answer a search either - the free-text column is what the member wrote.
      pending = insert_activated_user(last_name: "Pendent", username: "pendingdirsearch")

      insert(:work_experience,
        user: pending,
        organization: "Acme",
        organization_page: insert(:organization, name: "Rheinmetall Pending", status: "pending")
      )

      frozen = insert_activated_user(last_name: "Frostig", username: "frozendirsearch")

      insert(:work_experience,
        user: frozen,
        organization: "Acme",
        organization_page:
          insert(:organization, name: "Rheinmetall Frozen", frozen_at: ~N[2026-01-01 00:00:00])
      )

      assert found("rheinmetall", [:organization]) == []
    end

    test "several stations at the same employer are one result, not three" do
      # A set membership answers "has such a row", a join would answer "for each
      # such row" - and the window count would say 3 members where there is one.
      # `u.id IN (union of id sets)` is what enforces it; this test is
      # calibrated against the shape that would break it, a join.
      member = insert_activated_user(last_name: "Treu", username: "loyaldirsearch")

      for year <- [2010, 2014, 2018] do
        insert(:work_experience, user: member, organization: "Bosch GmbH", start_year: year)
      end

      assert %{users: [%{username: "loyaldirsearch"}], total: 1} =
               Directory.search("bosch gmbh", [:organization])
    end

    test "a multi-word query can span a name and an employer" do
      assert found("vergangen siemens") == ~w(pastdirsearch)
      assert found("siemens vergangen") == ~w(pastdirsearch)
      assert found("laufend siemens ag") == []
    end

    test "unconfirmed and moderation-hidden members stay out of a CV search" do
      insert(:work_experience, user: insert(:user, last_name: "Vage"), organization: "Nokia")

      insert(:work_experience,
        user: insert_activated_user(last_name: "Verboten", frozen_at: ~N[2026-01-01 00:00:00]),
        organization: "Nokia"
      )

      assert found("nokia", [:organization]) == []
    end
  end

  describe "matched_entries/3" do
    setup do
      %{member: insert_activated_user(last_name: "Wechsler", username: "matchdirsearch")}
    end

    test "names the entry a CV search found the member through", %{member: member} do
      # The row would otherwise show this member's current job, which is a
      # different company than the one that was typed.
      insert(:work_experience,
        user: member,
        title: "Developer",
        organization: "Siemens AG",
        start_year: 2012,
        end_year: 2016
      )

      assert %{organization: "Siemens AG", title: "Developer"} =
               matched("siemens", [:organization])
    end

    test "prefers the entry that matches more of the query", %{member: member} do
      insert(:work_experience, user: member, organization: "Siemens AG", start_year: 2000)

      insert(:work_experience,
        user: member,
        organization: "Siemens Healthineers",
        start_year: 2005,
        end_year: 2009
      )

      assert %{organization: "Siemens Healthineers"} =
               matched("siemens healthineers", [:organization])
    end

    test "prefers a running role over one that ended", %{member: member} do
      insert(:work_experience,
        user: member,
        organization: "Bosch GmbH",
        start_year: 2000,
        end_year: 2004
      )

      insert(:work_experience, user: member, organization: "Bosch GmbH", start_year: 2010)

      entry = matched("bosch", [:organization])

      assert entry.start_year == 2010
      assert is_nil(entry.end_year)
    end

    test "work wins over education when both answer", %{member: member} do
      insert(:work_experience, user: member, organization: "Bremen Marketing", start_year: 2015)
      insert(:education, user: member, school: "Universität Bremen")

      assert %WorkExperience{} = matched("bremen", [:organization, :school])
    end

    test "an education match returns the education entry", %{member: member} do
      insert(:education, user: member, school: "Universität Bremen", degree: "Diplom")

      assert %{school: "Universität Bremen", degree: "Diplom"} = matched("bremen", [:school])
    end

    test "a member the name fields already explain keeps their current job", %{member: member} do
      # "anna" finds her by first name, and her 2005 employer happens to carry
      # the same letters. The row must not be taken over by a company nobody
      # was looking for: the CV line is for members the name fields could not
      # have found.
      anna = insert_activated_user(first_name: "Anna", last_name: "Bergsteiger")

      insert(:work_experience,
        user: anna,
        organization: "Annapurna Trekking GmbH",
        start_year: 2005
      )

      insert(:work_experience,
        user: member,
        organization: "Annapurna Trekking GmbH",
        start_year: 2005
      )

      %{users: users} = Directory.search("anna", Directory.search_fields())
      entries = Directory.matched_entries(users, "anna", Directory.search_fields())

      refute Map.has_key?(entries, anna.id)
      # Wechsler carries the same employer and no "anna" in any name, so she is
      # here *because* of the CV field and her row has to say so.
      assert Map.has_key?(entries, member.id)
    end

    test "a search with no CV field ticked asks nothing of the CV tables", %{member: member} do
      insert(:work_experience, user: member, organization: "Siemens AG")

      %{users: users} = Directory.search("wechsler", [:last_name])

      assert Directory.matched_entries(users, "wechsler", [:last_name]) == %{}
    end

    defp matched(query, fields) do
      %{users: users} = Directory.search(query, fields)

      case Directory.matched_entries(users, query, fields) do
        map when map_size(map) == 1 -> map |> Map.values() |> hd()
        map -> map
      end
    end
  end

  defp counts_by_letter do
    Map.new(Directory.letter_entries(), &{&1.letter, &1.count})
  end
end
