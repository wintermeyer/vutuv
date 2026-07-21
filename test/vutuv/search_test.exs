defmodule Vutuv.SearchTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Accounts.SearchTerm
  alias Vutuv.Search
  alias Vutuv.Search.SearchQuery

  # A user findable by name search: the factory does not create search terms
  # (Accounts.create_user does), so insert the same terms create_user would.
  defp searchable_user(first, last, attrs \\ []) do
    user = insert(:activated_user, Keyword.merge([first_name: first, last_name: last], attrs))

    for changeset <-
          SearchTerm.create_search_terms(%{
            "first_name" => first,
            "last_name" => last
          }) do
      changeset |> Ecto.Changeset.put_change(:user_id, user.id) |> Repo.insert!()
    end

    user
  end

  describe "instant/1" do
    test "returns nil below the minimum query length" do
      assert Search.instant("") == nil
      assert Search.instant("ab") == nil
      assert Search.instant("  a  ") == nil
    end

    test "splits people into exact prefix matches and similar-sounding ones" do
      meier = searchable_user("Maria", "Meier")
      mayer = searchable_user("Mia", "Mayer")

      results = Search.instant("Meier")

      assert Enum.map(results.exact_people, & &1.id) == [meier.id]
      assert Enum.map(results.similar_people, & &1.id) == [mayer.id]
    end

    test "matches inside a name, not just at its start" do
      mueller = searchable_user("Hans", "Müller")
      searchable_user("Heinz", "Mehler")

      results = Search.instant("üller")

      assert Enum.map(results.exact_people, & &1.id) == [mueller.id]
    end

    test "a typo'd umlaut name still matches phonetically, not only in ASCII" do
      mueller = searchable_user("Hans", "Müller")

      # "müler" is not a substring of "Müller", so only the Cologne/Soundex path
      # can match. Before the fix the search side left the ü literal ("6ü57")
      # while the stored term is "657", so umlaut names never fuzzy-matched.
      results = Search.instant("müler")

      assert mueller.id in Enum.map(results.similar_people, & &1.id)
    end

    test "narrows as the query grows" do
      searchable_user("Maria", "Meier")
      searchable_user("Martin", "Meixner")

      assert length(Search.instant("mei").exact_people) == 2
      assert [%{last_name: "Meier"}] = Search.instant("meie").exact_people
    end

    test "a user matched exactly never repeats in the similar group" do
      meier = searchable_user("Maria", "Meier")

      results = Search.instant("meier")

      assert Enum.map(results.exact_people, & &1.id) == [meier.id]
      assert results.similar_people == []
    end

    test "skips deactivated users" do
      searchable_user("Hidden", "Person", email_confirmed?: false)

      results = Search.instant("hidden")

      assert results.exact_people == []
      assert results.similar_people == []
    end

    test "an email-shaped query matches the email exactly" do
      user = insert(:activated_user)
      insert(:email, user: user, value: "findme@example.com", public?: true)

      results = Search.instant("findme@example.com")

      assert Enum.map(results.exact_people, & &1.id) == [user.id]
      assert results.similar_people == []
    end

    test "an address on a long modern TLD is still recognized as an email" do
      user = insert(:activated_user)
      insert(:email, user: user, value: "anna@example.online", public?: true)

      results = Search.instant("anna@example.online")

      assert Enum.map(results.exact_people, & &1.id) == [user.id]
      assert results.similar_people == []
    end

    test "a private email address is not findable" do
      # public? defaults to false; the owner controls discoverability, so a
      # private address must not even confirm that an account exists.
      user = insert(:activated_user)
      insert(:email, user: user, value: "hidden@example.com", public?: false)

      results = Search.instant("hidden@example.com")

      assert results.exact_people == []
      assert results.similar_people == []
    end

    test "tags match by name or slug prefix, case-insensitively" do
      name = unique_tag_name("Elixir")
      tag = insert(:tag, name: name, slug: String.downcase(name))
      insert(:tag)

      assert Enum.map(Search.instant("eLi").tags, & &1.id) == [tag.id]
    end

    test "the tag member count excludes unactivated and moderation-hidden members" do
      name = unique_tag_name("Elixir")
      tag = insert(:tag, name: name, slug: String.downcase(name))

      visible = searchable_user("Vera", "Visible")
      unactivated = insert(:user, email_confirmed?: false)
      frozen = searchable_user("Fred", "Frozen", frozen_at: ~N[2026-01-01 00:00:00])

      for u <- [visible, unactivated, frozen], do: insert(:user_tag, tag: tag, user: u)

      # Three rows in the DB, but only the one visible member should be counted —
      # matching what the tag page (Tag.recommended_users) actually shows.
      assert Search.instant("eli").tag_member_counts[tag.id] == 1
    end

    test "matching public posts are included" do
      author = insert(:activated_user)
      post = Vutuv.PostsHelpers.create_post!(author, %{body: "Quantum gardening tips"})

      assert Enum.map(Search.instant("quantum gardening").posts, & &1.id) == [post.id]
    end

    test "a LIKE wildcard in the query is treated literally" do
      searchable_user("Maria", "Meier")

      results = Search.instant("%%%")

      assert results.exact_people == []
      assert results.similar_people == []
    end
  end

  describe "parse/2" do
    test "plain text parses with defaults" do
      assert %{text: "maria meier", scope: :all, exact?: false, tag: nil} =
               Search.parse("  Maria Meier ")
    end

    test "field operators and their aliases" do
      assert %{first_name: "stefan", last_name: "meier", scope: :people} =
               Search.parse("vorname:stefan nachname:meier")

      assert %{first_name: "stefan", last_name: "meier"} =
               Search.parse("first:stefan last:meier")

      # tag:/skill: now spans people and posts (issue #946), so it no longer
      # pins the scope to :people — it leaves the scope free (default :all).
      assert %{tag: "elixir", scope: :all, scope_pinned?: false} = Search.parse("tag:elixir")
      assert %{tag: "elixir", scope: :all} = Search.parse("skill:elixir")
      assert %{slug: "stefan", scope: :people} = Search.parse("@stefan")
      assert %{city: "koblenz", scope: :people} = Search.parse("ort:koblenz")
      assert %{city: "koblenz"} = Search.parse("stadt:koblenz")
      assert %{city: "koblenz"} = Search.parse("city:koblenz")

      assert %{text: "müller", tag: "php", city: "koblenz"} =
               Search.parse("müller tag:php ort:koblenz")
    end

    test "a fully quoted query turns on exact" do
      assert %{text: "maria meier", exact?: true} = Search.parse(~s("Maria Meier"))
    end

    test "options pass the UI scope and exact toggle" do
      assert %{scope: :posts, exact?: true} = Search.parse("meier", scope: :posts, exact: true)
      # Field operators override the chip scope.
      assert %{scope: :people} = Search.parse("nachname:meier", scope: :posts)
      # Unknown scopes fall back to :all.
      assert %{scope: :all} = Search.parse("meier", scope: :bogus)
    end

    test "people-only operators mark the scope as pinned, plain queries do not" do
      assert %{scope_pinned?: true} = Search.parse("city:hamburg", scope: :posts)
      assert %{scope_pinned?: true} = Search.parse("@stefan")
      assert %{scope_pinned?: false} = Search.parse("meier", scope: :tags)
      assert %{scope_pinned?: false} = Search.parse("meier")
      # tag: spans people and posts now, so it does not pin (issue #946); it
      # honors the chip scope like a plain query does.
      assert %{scope_pinned?: false, scope: :posts} = Search.parse("tag:php", scope: :posts)
      assert %{scope_pinned?: false, scope: :tags} = Search.parse("tag:php", scope: :tags)
    end

    test "an unknown operator stays ordinary text" do
      assert %{text: "foo:bar", tag: nil} = Search.parse("foo:bar")
    end

    test "the status operator parses open/looking and pins the scope" do
      assert %{status: "looking", scope: :people, scope_pinned?: true} =
               Search.parse("status:looking")

      assert %{status: "open", scope: :people} = Search.parse("status:open")
    end

    test "an unknown status value degrades to plain text" do
      assert %{status: nil, text: "status:employed"} = Search.parse("status:employed")
    end
  end

  describe "status operator matching" do
    setup do
      viewer = insert(:activated_user)

      looking =
        insert(:activated_user,
          first_name: "Lea",
          last_name: "Looking",
          employment_status: "looking",
          employment_status_visibility: "members"
        )

      %{viewer: viewer, looking: looking}
    end

    test "a signed-in viewer matches members by visible status", ctx do
      insert(:activated_user, employment_status: "open", employment_status_visibility: "members")

      results = Search.instant("status:looking", viewer: ctx.viewer)
      assert Enum.map(results.exact_people, & &1.id) == [ctx.looking.id]
    end

    test "a hidden status never matches", ctx do
      insert(:activated_user,
        employment_status: "looking",
        employment_status_visibility: "hidden"
      )

      results = Search.instant("status:looking", viewer: ctx.viewer)
      assert Enum.map(results.exact_people, & &1.id) == [ctx.looking.id]
    end

    test "logged-out search ignores the operator", ctx do
      # No viewer → the status operator is dropped, so a bare status query has
      # nothing to match and returns no people.
      results = Search.instant("status:looking")
      assert results == nil or results.exact_people == []
      refute ctx.looking.id in Enum.map((results && results.exact_people) || [], & &1.id)
    end

    test "status combines with a tag filter", ctx do
      name = unique_tag_name("Elixir")
      tag = insert(:tag, name: name, slug: String.downcase(name))
      insert(:user_tag, tag: tag, user: ctx.looking)
      # A looking member without the tag must not match.
      insert(:activated_user,
        employment_status: "looking",
        employment_status_visibility: "members"
      )

      results = Search.instant("status:looking tag:#{tag.slug}", viewer: ctx.viewer)
      assert Enum.map(results.exact_people, & &1.id) == [ctx.looking.id]
    end
  end

  describe "instant/2 with operators and filters" do
    test "exact mode matches whole name terms only" do
      meier = searchable_user("Maria", "Meier")
      searchable_user("Mia", "Mayer")
      searchable_user("Dominik", "Meierhofer")

      results = Search.instant("meier", exact: true)

      assert Enum.map(results.exact_people, & &1.id) == [meier.id]
      assert results.similar_people == []

      # The same via quotes instead of the toggle.
      quoted = Search.instant(~s("meier"))
      assert Enum.map(quoted.exact_people, & &1.id) == [meier.id]
    end

    test "vorname:/nachname: search a single name field" do
      meier = searchable_user("Stefan", "Meier")
      searchable_user("Meier", "Stefan")

      results = Search.instant("nachname:meier")
      assert Enum.map(results.exact_people, & &1.id) == [meier.id]

      results = Search.instant("vorname:stefan nachname:meier")
      assert Enum.map(results.exact_people, & &1.id) == [meier.id]
    end

    test "@handle searches the username" do
      user = insert(:activated_user, username: "stefan.w#{System.unique_integer([:positive])}")
      insert(:activated_user, username: "unrelated")

      results = Search.instant("@stefan")

      assert Enum.map(results.exact_people, & &1.id) == [user.id]
    end

    test "tag: lists people with that tag, not the tag itself" do
      name = unique_tag_name("PHP")
      tag = insert(:tag, name: name, slug: String.downcase(name))
      with_tag = insert(:activated_user, first_name: "Paula", last_name: "Programmer")
      insert(:user_tag, tag: tag, user: with_tag)
      insert(:activated_user, first_name: "Norbert", last_name: "NoTag")
      author = insert(:activated_user)
      Vutuv.PostsHelpers.create_post!(author, %{body: "All about #{tag.slug}"})

      results = Search.instant("tag:#{tag.slug}")

      assert Enum.map(results.exact_people, & &1.id) == [with_tag.id]
      assert results.tags == []
      assert results.posts == []
    end

    test "a name combines with the tag filter" do
      name = unique_tag_name("PHP")
      php_tag = insert(:tag, name: name, slug: String.downcase(name))
      php_mueller = searchable_user("Hans", "Müller")
      insert(:user_tag, tag: php_tag, user: php_mueller)
      searchable_user("Heike", "Müller")

      results = Search.instant("müller tag:#{php_tag.slug}")

      assert Enum.map(results.exact_people, & &1.id) == [php_mueller.id]
    end

    test "tag: also finds posts carrying that tag, matching the tag not the body (issue #946)" do
      name = unique_tag_name("PHP")
      tag = insert(:tag, name: name, slug: String.downcase(name))
      with_tag = insert(:activated_user)
      insert(:user_tag, tag: tag, user: with_tag)

      author = insert(:activated_user)
      tagged = Vutuv.PostsHelpers.create_post!(author, %{body: "My write-up", tags: tag.slug})

      _untagged =
        Vutuv.PostsHelpers.create_post!(author, %{body: "#{tag.slug} but not tagged"})

      results = Search.instant("tag:#{tag.slug}")

      # People AND posts both respond to the tag filter now; the untagged post
      # that merely mentions "php" in its body stays out.
      assert with_tag.id in Enum.map(results.exact_people, & &1.id)
      assert Enum.map(results.posts, & &1.id) == [tagged.id]
    end

    test "the Posts scope with a tag: filter returns only posts" do
      name = unique_tag_name("PHP")
      tag = insert(:tag, name: name, slug: String.downcase(name))
      with_tag = insert(:activated_user)
      insert(:user_tag, tag: tag, user: with_tag)

      tagged =
        Vutuv.PostsHelpers.create_post!(insert(:activated_user), %{body: "hi", tags: tag.slug})

      results = Search.instant("tag:#{tag.slug}", scope: :posts)

      assert results.exact_people == []
      assert Enum.map(results.posts, & &1.id) == [tagged.id]
    end

    test "a name combines with the city filter" do
      koblenz_mueller = searchable_user("Hans", "Müller")
      insert(:address, user: koblenz_mueller, city: "Koblenz")
      berlin_mueller = searchable_user("Heike", "Müller")
      insert(:address, user: berlin_mueller, city: "Berlin")

      results = Search.instant("müller ort:koblenz")

      assert Enum.map(results.exact_people, & &1.id) == [koblenz_mueller.id]
    end

    test "the city filter also narrows the similar-names group" do
      koblenz_mayer = searchable_user("Mia", "Mayer")
      insert(:address, user: koblenz_mayer, city: "Koblenz")
      searchable_user("Moritz", "Mayer")

      results = Search.instant("meier ort:koblenz")

      assert Enum.map(results.similar_people, & &1.id) == [koblenz_mayer.id]
    end

    test "a pure filter query lists everyone matching" do
      koblenzer = insert(:activated_user, first_name: "Karla", last_name: "Koblenzerin")
      insert(:address, user: koblenzer, city: "Koblenz")
      insert(:activated_user, first_name: "Bert", last_name: "Berliner")

      results = Search.instant("ort:koblenz")

      assert Enum.map(results.exact_people, & &1.id) == [koblenzer.id]
    end

    test "tags carry their member counts" do
      name = unique_tag_name("Elixir")
      tag = insert(:tag, name: name, slug: String.downcase(name))
      insert(:user_tag, tag: tag, user: insert(:activated_user))
      insert(:user_tag, tag: tag, user: insert(:activated_user))

      results = Search.instant(tag.slug)

      assert results.tag_member_counts[tag.id] == 2
    end

    test "the scope filter limits what is searched" do
      searchable_user("Elia", "Tester")
      name = unique_tag_name("Elixir")
      insert(:tag, name: name, slug: String.downcase(name))
      author = insert(:activated_user)
      Vutuv.PostsHelpers.create_post!(author, %{body: "All about elixir and more"})

      people_only = Search.instant("eli", scope: :people)
      assert people_only.exact_people != []
      assert people_only.tags == []
      assert people_only.posts == []

      tags_only = Search.instant("eli", scope: :tags)
      assert tags_only.exact_people == []
      assert tags_only.tags != []
      assert tags_only.posts == []

      posts_only = Search.instant("elixir", scope: :posts)
      assert posts_only.exact_people == []
      assert posts_only.tags == []
      assert posts_only.posts != []
    end

    test "a short operator value is enough to search" do
      user = insert(:activated_user, username: "st-w")

      assert Search.instant("@st") |> Map.fetch!(:exact_people) |> Enum.map(& &1.id) ==
               [user.id]

      # ...but a bare two-letter query still is not.
      assert Search.instant("st") == nil
    end
  end

  describe "record_query/2" do
    test "stores the query with its user results and an anonymous requester" do
      user = searchable_user("Maria", "Meier")

      assert {:ok, query} = Search.record_query("Meier", nil)

      query = Repo.preload(query, [:user_results, :search_query_requesters])
      assert query.value == "meier"
      refute query.email?
      assert Enum.map(query.user_results, & &1.id) == [user.id]
      assert [%{user_id: nil}] = query.search_query_requesters
    end

    test "repeating a query in another case reuses the stored row" do
      requester = insert(:activated_user)

      assert {:ok, _query} = Search.record_query("smith", nil)
      assert {:ok, _query} = Search.record_query("Smith", requester)

      assert Repo.aggregate(SearchQuery, :count) == 1
      assert Repo.aggregate(Vutuv.Search.SearchQueryRequester, :count) == 2
    end

    test "an email query records the matched user as a result" do
      user = insert(:activated_user)
      insert(:email, user: user, value: "findme@example.com")

      assert {:ok, query} = Search.record_query("findme@example.com", nil)

      assert query.email?
      assert Enum.map(Repo.preload(query, :user_results).user_results, & &1.id) == [user.id]
    end

    test "an over-long query is skipped, not raised (varchar(255) column)" do
      # A ?q= URL can carry an arbitrarily long query with no client maxlength;
      # it must not crash-loop SearchLive with a Postgres 22001.
      assert {:error, %Ecto.Changeset{}} = Search.record_query(String.duplicate("a", 300), nil)
      assert Repo.aggregate(SearchQuery, :count) == 0
    end
  end
end
