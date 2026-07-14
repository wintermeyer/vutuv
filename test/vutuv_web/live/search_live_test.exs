defmodule VutuvWeb.SearchLiveTest do
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers

  alias Vutuv.Accounts.SearchTerm
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

  describe "the live search page" do
    test "renders the search form with tips for an empty query", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/search")

      assert has_element?(view, "#search-form input[name=q]")
      assert html =~ "words in public posts"
    end

    test "shows a hint instead of results below three letters", %{conn: conn} do
      searchable_user("Maria", "Meier")

      {:ok, view, _html} = live(conn, ~p"/search")
      view |> form("#search-form") |> render_change(%{q: "me"})
      assert_patch(view, ~p"/search?q=me")

      html = render(view)
      assert has_element?(view, "#search-hint")
      refute html =~ "Maria Meier"
    end

    test "results appear live after three letters and the URL follows", %{conn: conn} do
      searchable_user("Maria", "Meier")

      {:ok, view, _html} = live(conn, ~p"/search")
      view |> form("#search-form") |> render_change(%{q: "mei"})
      assert_patch(view, ~p"/search?q=mei")

      assert render(view) =~ "Maria Meier"
    end

    test "a ?q= URL renders its results on first load", %{conn: conn} do
      searchable_user("Maria", "Meier")

      {:ok, _view, html} = live(conn, ~p"/search?q=meier")

      assert html =~ "Maria Meier"
    end

    test "narrowing the query narrows the result list", %{conn: conn} do
      searchable_user("Maria", "Meier")
      searchable_user("Martin", "Meixner")

      {:ok, view, _html} = live(conn, ~p"/search?q=mei")
      html = render(view)
      assert html =~ "Maria Meier"
      assert html =~ "Martin Meixner"

      view |> form("#search-form") |> render_change(%{q: "meie"})
      assert_patch(view, ~p"/search?q=meie")

      html = render(view)
      assert html =~ "Maria Meier"
      refute html =~ "Martin Meixner"
    end

    test "exact and similar-sounding matches are visually separated", %{conn: conn} do
      searchable_user("Maria", "Meier")
      searchable_user("Mia", "Mayer")

      {:ok, view, _html} = live(conn, ~p"/search?q=meier")

      assert has_element?(view, "#search-people-exact", "Maria Meier")
      refute has_element?(view, "#search-people-exact", "Mia Mayer")
      assert has_element?(view, "#search-people-similar", "Mia Mayer")
      refute has_element?(view, "#search-people-similar", "Maria Meier")
    end

    test "an email-shaped query finds the user with that address", %{conn: conn} do
      user = insert(:activated_user, first_name: "Erika", last_name: "Muster")
      insert(:email, user: user, value: "findme@example.com")

      {:ok, view, _html} = live(conn, ~p"/search?q=findme@example.com")

      assert has_element?(view, "#search-people-exact", "Erika Muster")
    end

    test "deactivated users never surface", %{conn: conn} do
      searchable_user("Hidden", "Person", email_confirmed?: false)

      {:ok, _view, html} = live(conn, ~p"/search?q=hidden")

      refute html =~ "Hidden Person"
    end

    test "matching tags show as chips linking to the tag page", %{conn: conn} do
      insert(:tag, name: "Elixir", slug: "elixir")

      {:ok, view, _html} = live(conn, ~p"/search?q=eli")

      assert has_element?(view, ~s(#search-tags a[href="/tags/elixir"]), "Elixir")
    end

    test "matching public posts show with author and permalink", %{conn: conn} do
      author = insert(:activated_user)
      post = create_post!(author, %{body: "Quantum gardening tips for beginners"})

      {:ok, view, _html} = live(conn, ~p"/search?q=quantum gardening")

      # The match markers (<mark>) sit inside the excerpt, so assert on the
      # text content, not the raw HTML string.
      assert has_element?(view, "#search-posts", "Quantum gardening tips")
      assert render(view) =~ ~p"/#{author}/posts/#{post.id}"
      assert has_element?(view, "#search-posts")
    end

    test "a restricted post never surfaces", %{conn: conn} do
      author = insert(:activated_user)

      create_post!(author, %{
        body: "Quantum gardening secrets",
        denials: [%{"wildcard" => "non_followers"}]
      })

      {:ok, _view, html} = live(conn, ~p"/search?q=quantum")

      refute html =~ "Quantum gardening secrets"
    end

    test "no results renders an explicit empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search?q=zzzz")

      assert has_element?(view, "#search-empty")
    end

    test "a settled query is recorded, typing alone is not", %{conn: conn} do
      searchable_user("Maria", "Meier")

      {:ok, view, _html} = live(conn, ~p"/search")
      view |> form("#search-form") |> render_change(%{q: "meier"})
      assert_patch(view, ~p"/search?q=meier")

      # Recording waits for the settle timer, so nothing is stored yet.
      refute Repo.exists?(SearchQuery)

      # Fire the settle timer by hand instead of sleeping through it.
      send(view.pid, {:record_query, "meier"})
      render(view)

      assert Repo.get_by(SearchQuery, value: "meier")
    end
  end

  describe "match highlighting" do
    test "the matched substring is marked in people names", %{conn: conn} do
      searchable_user("Hans", "Müller")

      {:ok, view, _html} = live(conn, ~p"/search?q=üller")

      assert has_element?(view, "#search-people-exact mark", "üller")
      assert has_element?(view, "#search-people-exact", "Hans Müller")
    end

    test "similar names carry no marker - nothing matched literally", %{conn: conn} do
      searchable_user("Maria", "Meier")
      searchable_user("Mia", "Mayer")

      {:ok, view, _html} = live(conn, ~p"/search?q=meier")

      assert has_element?(view, "#search-people-exact mark", "Meier")
      refute has_element?(view, "#search-people-similar mark")
    end

    test "field operators mark their value in the name", %{conn: conn} do
      searchable_user("Stefan", "Meier")

      {:ok, view, _html} = live(conn, ~p"/search?q=nachname:meier")

      assert has_element?(view, "#search-people-exact mark", "Meier")
    end

    test "tag and post matches are marked too", %{conn: conn} do
      insert(:tag, name: "Elixir", slug: "elixir")
      author = insert(:activated_user)
      create_post!(author, %{body: "Quantum gardening tips for beginners"})

      {:ok, view, _html} = live(conn, ~p"/search?q=lix")
      assert has_element?(view, "#search-tags mark", "lix")

      {:ok, view, _html} = live(conn, ~p"/search?q=gardening")
      assert has_element?(view, "#search-posts mark", "gardening")
    end
  end

  describe "filters and operators" do
    test "the empty page documents the operator syntax", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/search")

      # The test locale is English, so the English operator spellings show.
      assert has_element?(view, "#search-syntax")
      assert html =~ "first:stefan"
      assert html =~ "tag:php"
      assert html =~ "city:koblenz"
    end

    test "the scope chips narrow the search and the URL carries the filter", %{conn: conn} do
      searchable_user("Elia", "Tester")
      insert(:tag, name: "Elixir", slug: "elixir")

      {:ok, view, _html} = live(conn, ~p"/search?q=eli")
      assert has_element?(view, "#search-people")
      assert has_element?(view, "#search-tags")

      view |> element("#search-scope-people") |> render_click()
      assert_patch(view, ~p"/search?q=eli&scope=people")

      assert has_element?(view, "#search-people")
      refute has_element?(view, "#search-tags")
    end

    test "the exact toggle drops prefix and phonetic matches", %{conn: conn} do
      searchable_user("Maria", "Meier")
      searchable_user("Mia", "Mayer")
      searchable_user("Dominik", "Meierhofer")

      {:ok, view, _html} = live(conn, ~p"/search?q=meier")
      assert has_element?(view, "#search-people-similar")
      assert render(view) =~ "Meierhofer"

      view |> element("#search-exact-toggle") |> render_click()
      assert_patch(view, ~p"/search?q=meier&exact=1")

      html = render(view)
      assert html =~ "Maria Meier"
      refute html =~ "Meierhofer"
      refute has_element?(view, "#search-people-similar")
    end

    test "filters survive further typing", %{conn: conn} do
      searchable_user("Maria", "Meier")

      {:ok, view, _html} = live(conn, ~p"/search?q=mei&scope=people&exact=1")
      view |> form("#search-form") |> render_change(%{q: "meier"})

      assert_patch(view, ~p"/search?q=meier&scope=people&exact=1")
    end

    test "a field operator searches only that field and highlights People", %{conn: conn} do
      searchable_user("Stefan", "Meier")
      searchable_user("Meier", "Stefan")

      {:ok, view, _html} = live(conn, ~p"/search?q=nachname:meier")

      assert has_element?(view, "#search-people-exact", "Stefan Meier")
      refute has_element?(view, "#search-people-exact", "Meier Stefan")
      assert has_element?(view, "#search-scope-people.bg-brand-600")
    end

    test "@handle finds the member by username", %{conn: conn} do
      insert(:activated_user,
        first_name: "Stefan",
        last_name: "Wintermeyer",
        username: "stefan.wintermeyer"
      )

      {:ok, view, _html} = live(conn, ~p"/search?q=@stefan")

      assert has_element?(view, "#search-people-exact", "Stefan Wintermeyer")
    end

    test "tag chips carry member counts", %{conn: conn} do
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      insert(:user_tag, tag: tag, user: insert(:activated_user))

      {:ok, view, _html} = live(conn, ~p"/search?q=elixir")

      assert has_element?(view, "#search-tags", "Elixir")
      assert has_element?(view, "#search-tags", "1")
    end

    # Issue #846: with a people operator in the query the parser pins the
    # search to people, so the other scope chips did nothing when clicked.
    # They must read as disabled instead of as working tabs.
    test "a people operator disables the other scope chips with a hint", %{conn: conn} do
      tag = insert(:tag, name: "PHP", slug: "php")
      insert(:user_tag, tag: tag, user: insert(:activated_user))

      {:ok, view, _html} = live(conn, ~p"/search?q=tag:php")

      # People is highlighted as what the search actually did ...
      assert has_element?(view, "#search-scope-people.bg-brand-600")
      # ... and the other scopes render as static disabled chips, not links.
      for scope <- ~w(all tags posts) do
        refute has_element?(view, "a#search-scope-#{scope}")
        assert has_element?(view, ~s(span#search-scope-#{scope}[aria-disabled="true"]))
      end

      assert has_element?(view, "#search-scope-pinned-hint")
      # The exact toggle still applies to operator queries, so it stays a link.
      assert has_element?(view, "a#search-exact-toggle")
    end

    test "clearing the operator re-enables the scope chips", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search?q=tag:php")
      refute has_element?(view, "a#search-scope-tags")

      view |> form("#search-form") |> render_change(%{q: "php"})
      assert_patch(view, ~p"/search?q=php")

      assert has_element?(view, "a#search-scope-tags")
      refute has_element?(view, "#search-scope-pinned-hint")
    end

    test "tag: lists the people with that tag instead of the tag itself", %{conn: conn} do
      tag = insert(:tag, name: "PHP", slug: "php")
      tagged = insert(:activated_user, first_name: "Paula", last_name: "Programmer")
      insert(:user_tag, tag: tag, user: tagged)
      insert(:activated_user, first_name: "Norbert", last_name: "NoTag")

      {:ok, view, _html} = live(conn, ~p"/search?q=tag:php")

      assert has_element?(view, "#search-people-exact", "Paula Programmer")
      refute has_element?(view, "#search-people-exact", "Norbert NoTag")
      refute has_element?(view, "#search-tags")
    end

    test "a name combines with tag and city filters", %{conn: conn} do
      tag = insert(:tag, name: "PHP", slug: "php")
      php_mueller = searchable_user("Hans", "Müller")
      insert(:user_tag, tag: tag, user: php_mueller)
      koblenz_mueller = searchable_user("Klara", "Müller")
      insert(:address, user: koblenz_mueller, city: "Koblenz")
      searchable_user("Heike", "Müller")

      {:ok, view, _html} = live(conn, ~p"/search?q=müller tag:php")
      assert has_element?(view, "#search-people-exact", "Hans Müller")
      refute has_element?(view, "#search-people-exact", "Heike Müller")

      {:ok, view, _html} = live(conn, ~p"/search?q=müller ort:koblenz")
      assert has_element?(view, "#search-people-exact", "Klara Müller")
      refute has_element?(view, "#search-people-exact", "Hans Müller")
    end
  end

  describe "legacy search URLs" do
    test "a stored-query URL replays as a live search", %{conn: conn} do
      conn = get(conn, "/search/smith")

      assert redirected_to(conn, 301) == "/search?q=smith"
    end

    test "the old POST endpoint bounces into the live search", %{conn: conn} do
      conn = post(conn, ~p"/search", search_query: %{"value" => "Smith"})

      assert redirected_to(conn, 303) == "/search?q=Smith"
    end

    test "a blank old-style POST lands on the empty search page", %{conn: conn} do
      conn = post(conn, ~p"/search", search_query: %{"value" => "   "})

      assert redirected_to(conn, 303) == "/search"
    end
  end

  describe "save search (#935)" do
    test "no save control for a plain free-text search", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      searchable_user("Max", "Meier")

      {:ok, view, _html} = live(conn, ~p"/search?#{[q: "meier"]}")
      refute has_element?(view, "#people-save-search-button")
    end

    test "a member saves a status people search as an alert", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      insert(:activated_user,
        employment_status: "looking",
        employment_status_visibility: "members"
      )

      {:ok, view, _html} = live(conn, ~p"/search?#{[q: "status:looking"]}")
      assert has_element?(view, "#people-save-search-button")

      view |> element("#people-save-search-button") |> render_click()
      view |> form("#people-save-search-form", %{notify: "weekly"}) |> render_submit()

      assert [search] = Vutuv.SavedSearches.list_for_user(user).entries
      assert search.kind == :people
      assert search.notify == :weekly
      assert search.query =~ "status"
    end
  end
end
