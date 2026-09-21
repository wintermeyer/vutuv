defmodule Vutuv.SearchOrganizationsTest do
  @moduledoc """
  The search page's answer (`Vutuv.Search.page/2`): organizations as a kind of
  result of their own, the people found through the employers and schools on
  their CVs, and the totals and pages every kind carries once "All" previews
  each kind and a kind's own scope pages through it.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.SearchHelpers

  alias Vutuv.Organizations
  alias Vutuv.Search

  defp ids(users), do: users |> Enum.map(& &1.id) |> Enum.sort()

  describe "people found through their CV" do
    test "an employer a member lists finds them, a role they left as well as one they hold" do
      current = insert(:activated_user)
      former = insert(:activated_user)
      insert(:work_experience, user: current, organization: "Quillmark Werke")

      insert(:work_experience,
        user: former,
        organization: "Quillmark Werke",
        start_year: 2010,
        end_year: 2016
      )

      people = Search.page("quillmark").people

      assert ids(people.cv) == ids([current, former])
      assert people.names == []
      assert people.main_total == 2
    end

    test "the name of a linked public page counts, a pending page's does not" do
      page = insert(:organization, name: "Brightwater Logistik")
      pending = insert(:organization, name: "Brightwater Pending", status: "pending")
      linked = insert(:activated_user)
      unlisted = insert(:activated_user)
      insert(:work_experience, user: linked, organization: "BWL", organization_id: page.id)
      insert(:work_experience, user: unlisted, organization: "BWP", organization_id: pending.id)

      assert ids(Search.page("brightwater").people.cv) == [linked.id]
    end

    test "a school finds the people who studied there" do
      student = insert(:activated_user)
      insert(:education, user: student, school: "Hochschule Tannenfeld")

      assert ids(Search.page("tannenfeld").people.cv) == [student.id]
    end

    test "somebody the name search already found is not listed twice" do
      named = searchable_user("Marta", "Quellbach")
      insert(:work_experience, user: named, organization: "Quellbach GmbH")

      people = Search.page("quellbach").people

      assert ids(people.names) == [named.id]
      assert people.cv == []
      assert people.main_total == 1
    end

    test "an unconfirmed or frozen member stays out" do
      unconfirmed = insert(:user, email_confirmed?: false)
      frozen = insert(:activated_user, frozen_at: ~N[2026-01-01 00:00:00])
      insert(:work_experience, user: unconfirmed, organization: "Mirelle Gruppe")
      insert(:work_experience, user: frozen, organization: "Mirelle Gruppe")

      assert Search.page("mirelle").people.cv == []
    end

    test "the CV matches are counted whole, and a page of people fetches only its slice" do
      named = searchable_user("Kestrel", "Ashwood")
      insert(:work_experience, user: named, organization: "Kestrel Instruments")

      employees =
        for n <- 1..4 do
          member = insert(:activated_user, last_name: "Mitarbeiter#{n}")
          insert(:work_experience, user: member, organization: "Kestrel Instruments")
          member
        end

      # "All" previews three rows but counts everybody.
      all = Search.page("kestrel").people
      assert ids(all.names) == [named.id]
      assert length(all.cv) == 2
      assert all.main_total == 5

      # Page 2 of two per page: the name match and the first CV match filled
      # page 1, so page 2 holds CV matches two and three.
      second = Search.page("kestrel", scope: :people, page: 2, per_page: 2).people
      assert second.page == 2
      assert second.names == []
      assert ids(second.cv) == ids(Enum.slice(employees, 1, 2))

      # A page past the last one shows the last one.
      assert Search.page("kestrel", scope: :people, page: 9, per_page: 2).people.page == 3
    end

    test "exact mode wants the whole employer name" do
      member = insert(:activated_user)
      insert(:work_experience, user: member, organization: "Ostwind Solar")

      assert Search.page("ostwind", exact: true).people.cv == []
      assert ids(Search.page("ostwind solar", exact: true).people.cv) == [member.id]
    end

    test "matched_entries/3 names the entry that answered, the running role first" do
      member = insert(:activated_user)

      insert(:work_experience,
        user: member,
        organization: "Pelikan Werft",
        title: "Trainee",
        start_year: 2008,
        end_year: 2010
      )

      insert(:work_experience,
        user: member,
        organization: "Pelikan Werft",
        title: "Werftleiterin",
        start_year: 2015
      )

      insert(:work_experience, user: member, organization: "Somewhere Else", title: "Beraterin")

      assert Search.matched_entries([member], "pelikan", false)[member.id].title ==
               "Werftleiterin"
    end

    test "matched_entries/3 falls back to the school" do
      member = insert(:activated_user)
      insert(:education, user: member, school: "Akademie Lindenhof")

      assert Search.matched_entries([member], "lindenhof", false)[member.id].school ==
               "Akademie Lindenhof"
    end

    test "instant/2, which the Mastodon API reads, stays the plain name matcher" do
      member = insert(:activated_user)
      insert(:work_experience, user: member, organization: "Quellwerk Nord")

      refute Map.has_key?(Search.instant("quellwerk"), :cv_people)
      assert Search.instant("quellwerk").exact_people == []
    end
  end

  describe "a name and an employer in one query" do
    test "finds the person of that name at that employer, and only them" do
      wanted = insert(:activated_user, first_name: "Lukas", last_name: "Kaiser")
      namesake = insert(:activated_user, first_name: "Lukas", last_name: "Brandl")
      colleague = insert(:activated_user, first_name: "Anna", last_name: "Weber")
      insert(:work_experience, user: wanted, organization: "Quarzwerk AG", title: "Entwickler")
      insert(:work_experience, user: namesake, organization: "Somewhere Else")
      insert(:work_experience, user: colleague, organization: "Quarzwerk AG")

      assert ids(Search.page("lukas quarzwerk").people.cv) == [wanted.id]
      assert ids(Search.page("quarzwerk lukas").people.cv) == [wanted.id]
    end

    test "the words may spread over a name and a school" do
      student = insert(:activated_user, first_name: "Ilvy", last_name: "Sandhagen")
      insert(:education, user: student, school: "Hochschule Tannenfeld")

      assert ids(Search.page("ilvy tannenfeld").people.cv) == [student.id]
    end

    test "a name alone is no CV match" do
      member = insert(:activated_user, first_name: "Quirinius", last_name: "Nord")
      insert(:work_experience, user: member, organization: "Elsewhere GmbH")

      assert Search.page("quirinius").people.cv == []
    end

    test "every word has to land somewhere" do
      member = insert(:activated_user, first_name: "Lukas", last_name: "Kaiser")
      insert(:work_experience, user: member, organization: "Quarzwerk AG")

      assert Search.page("lukas quarzwerk berlin").people.cv == []
    end

    test "a short word still narrows, it just does not drive the search" do
      ag = insert(:activated_user)
      gmbh = insert(:activated_user)
      insert(:work_experience, user: ag, organization: "Quarzwerk AG")
      insert(:work_experience, user: gmbh, organization: "Quarzwerk GmbH")

      assert ids(Search.page("quarzwerk ag").people.cv) == [ag.id]
    end

    test "a short word matches a whole word, never the inside of one" do
      student = insert(:activated_user)
      clerk = insert(:activated_user)
      insert(:education, user: student, school: "TU Tannenfeld")
      insert(:work_experience, user: clerk, organization: "Hauptverwaltung Tannenfeld")

      assert ids(Search.page("tu tannenfeld").people.cv) == [student.id]
    end

    test "the words of an employer have to stand in the same entry" do
      scattered = insert(:activated_user)
      insert(:work_experience, user: scattered, organization: "Zinnober Telekom")
      insert(:work_experience, user: scattered, organization: "Kobaltbank")
      banker = insert(:activated_user)
      insert(:work_experience, user: banker, organization: "Zinnober Kobaltbank AG")

      assert ids(Search.page("zinnober kobaltbank").people.cv) == [banker.id]
    end

    test "a username is not a name here, as it is not in the name search" do
      handle =
        insert(:activated_user, first_name: "Peter", last_name: "Braun", username: "lukasfan")

      insert(:work_experience, user: handle, organization: "Quarzwerk AG")

      assert Search.page("lukasfan quarzwerk").people.cv == []
    end

    test "the row names the entry the employer word matched" do
      member = insert(:activated_user, first_name: "Lukas", last_name: "Kaiser")
      insert(:work_experience, user: member, organization: "Nordlicht Studio", title: "Designer")
      insert(:work_experience, user: member, organization: "Quarzwerk AG", title: "Entwickler")

      assert Search.matched_entries([member], "lukas quarzwerk", false)[member.id].title ==
               "Entwickler"
    end
  end

  describe "the firma: and schule: operators" do
    test "a name with firma: finds that name among the people who worked there" do
      wanted = searchable_user("Petra", "Müllerstein")
      elsewhere = searchable_user("Paul", "Müllerstein")
      insert(:work_experience, user: wanted, organization: "Quarzwerk AG", end_year: 2019)
      insert(:work_experience, user: elsewhere, organization: "Somewhere Else")

      assert ids(Search.page("müllerstein firma:quarzwerk").people.names) == [wanted.id]
    end

    test "firma: keeps the similar-sounding names, filtered the same way" do
      exact = searchable_user("Petra", "Kolbinger")
      sounds_like = searchable_user("Paul", "Kohlbinger")
      insert(:work_experience, user: exact, organization: "Quarzwerk AG")
      insert(:work_experience, user: sounds_like, organization: "Quarzwerk AG")

      people = Search.page("kolbinger firma:quarzwerk").people

      assert ids(people.names) == [exact.id]
      assert ids(people.similar) == [sounds_like.id]
    end

    test "firma: alone lists everybody who worked there, the linked page's name included" do
      page = insert(:organization, name: "Quarzwerk Holding")
      own_text = insert(:activated_user)
      linked = insert(:activated_user)
      insert(:work_experience, user: own_text, organization: "Quarzwerk AG")
      insert(:work_experience, user: linked, organization: "QWH", organization_id: page.id)
      insert(:work_experience, user: insert(:activated_user), organization: "Somewhere Else")

      assert ids(Search.page("firma:quarzwerk").people.names) == ids([own_text, linked])
    end

    test "schule: finds the people who studied there" do
      student = insert(:activated_user)
      insert(:education, user: student, school: "Hochschule Tannenfeld")
      insert(:work_experience, user: insert(:activated_user), organization: "Tannenfeld GmbH")

      assert ids(Search.page("schule:tannenfeld").people.names) == [student.id]
    end

    test "a value under three letters is a whole word, as in the free text" do
      tu = insert(:activated_user)
      stuttgart = insert(:activated_user)
      insert(:education, user: tu, school: "TU Dortmund")
      insert(:education, user: stuttgart, school: "Universität Stuttgart")

      result = Search.page("schule:tu")

      assert ids(result.people.names) == [tu.id]
      assert Search.found_by(result.people, result.parsed)[tu.id].school == "TU Dortmund"
    end

    test "with an operator the free text is a name, not a CV word" do
      # Worked at a place called "Müllerstein Brot" and at Quarzwerk, but is
      # not called Müllerstein.
      baker = insert(:activated_user, first_name: "Bernd", last_name: "Baecker")
      insert(:work_experience, user: baker, organization: "Müllerstein Brot")
      insert(:work_experience, user: baker, organization: "Quarzwerk AG")

      assert Search.page("müllerstein firma:quarzwerk").people.cv == []
    end

    test "matched_entries/4 restricted to a kind names the entry of that kind" do
      member = insert(:activated_user)
      insert(:work_experience, user: member, organization: "Tannenfeld Werke", title: "Monteur")
      insert(:education, user: member, school: "Hochschule Tannenfeld")

      assert Search.matched_entries([member], "tannenfeld", false, :school)[member.id].school ==
               "Hochschule Tannenfeld"

      assert Search.matched_entries([member], "tannenfeld", false, :company)[member.id].title ==
               "Monteur"
    end
  end

  describe "organizations as a kind of result" do
    test "a public page is found by name, with the people its page lists" do
      page = insert(:organization, name: "Silberfluss Energie")
      insert(:organization, name: "Silberfluss Pending", status: "pending")
      insert(:organization, name: "Silberfluss Frozen", frozen_at: ~N[2026-01-01 00:00:00])

      for _ <- 1..2 do
        insert(:work_experience, user: insert(:activated_user), organization_id: page.id)
      end

      organizations = Search.page("silberfluss").organizations

      assert Enum.map(organizations.entries, & &1.id) == [page.id]
      assert organizations.total == 1
      assert organizations.people_counts[page.id] == 2
    end

    test "the organizations scope searches nothing else" do
      insert(:organization, name: "Kranichsee Bau")
      searchable_user("Kranich", "Tester")

      results = Search.page("kranich", scope: :organizations)

      assert [%{name: "Kranichsee Bau"}] = results.organizations.entries
      assert results.people.names == []
      assert results.tags.entries == []
      assert results.posts.entries == []
    end

    test "a people-only operator keeps organizations out" do
      insert(:organization, name: "Ortolan Werke")

      assert Search.page("ortolan ort:berlin").organizations.entries == []
    end
  end

  describe "totals and pages" do
    test "tags carry their total, and a page of the tags scope skips the ones before it" do
      base = unique_tag_name("Zirbe")

      tags =
        for suffix <- ~w(a b c) do
          name = base <> suffix
          insert(:tag, name: name, slug: Vutuv.SlugHelpers.tagify(name))
        end

      assert Search.page(String.downcase(base)).tags.total == 3

      page_two = Search.page(String.downcase(base), scope: :tags, page: 2, per_page: 2).tags
      assert page_two.total == 3
      assert Enum.map(page_two.entries, & &1.id) == [List.last(tags).id]
    end

    test "posts carry their total, and a page of the posts scope skips the ones before it" do
      author = insert(:activated_user)

      posts =
        for n <- 1..4 do
          Vutuv.PostsHelpers.create_post!(author, %{body: "Hagebuttenmarmelade Nummer #{n}"})
        end

      # "All" previews three and, finding the preview full, counts the rest.
      all = Search.page("hagebuttenmarmelade").posts
      assert length(all.entries) == 3
      assert all.total == 4

      first = Search.page("hagebuttenmarmelade", scope: :posts, page: 1, per_page: 3).posts
      second = Search.page("hagebuttenmarmelade", scope: :posts, page: 2, per_page: 3).posts

      assert length(first.entries) == 3
      assert length(second.entries) == 1
      assert Enum.sort(Enum.map(first.entries ++ second.entries, & &1.id)) == ids(posts)
    end
  end

  describe "an organization's people" do
    test "people_counts/1 counts every page's listed people in one go" do
      one = insert(:organization)
      two = insert(:organization)
      empty = insert(:organization)
      member = insert(:activated_user)
      insert(:work_experience, user: member, organization_id: one.id)
      insert(:work_experience, user: member, organization_id: one.id, title: "Second role")
      insert(:work_experience, user: insert(:activated_user), organization_id: two.id)

      insert(:work_experience,
        user: insert(:user, email_confirmed?: false),
        organization_id: two.id
      )

      counts = Organizations.people_counts([one.id, two.id, empty.id])

      assert counts[one.id] == 1
      assert counts[two.id] == 1
      assert Map.get(counts, empty.id, 0) == 0
    end

    test "a name narrows the page and its count" do
      page = insert(:organization)
      wanted = insert(:activated_user, first_name: "Ilvy", last_name: "Sandhagen")
      other = insert(:activated_user, first_name: "Bruno", last_name: "Kessler")
      insert(:work_experience, user: wanted, organization_id: page.id)
      insert(:work_experience, user: other, organization_id: page.id)

      result = Organizations.organization_people_page(page, query: "sandha")

      assert Enum.map(result.entries, & &1.user.id) == [wanted.id]
      assert Organizations.organization_people_count(page, query: "sandha") == 1
      assert Organizations.organization_people_count(page) == 2
    end
  end
end
