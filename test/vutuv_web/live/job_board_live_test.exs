defmodule VutuvWeb.JobBoardLiveTest do
  @moduledoc """
  The public `/jobs` board LiveView (issue #933): rendering, URL-shareable
  filters, the signed-in-only chips, a live like from a card, and a posting
  appearing live over PubSub while the board is open.
  """

  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.JobsHelpers

  alias Vutuv.Jobs

  test "renders published postings and the board heading", %{conn: conn} do
    poster = poster_fixture()
    publish_job!(poster, %{"title" => "Elixir Engineer"})

    {:ok, view, html} = live(conn, ~p"/jobs")

    assert html =~ "Elixir Engineer"
    assert has_element?(view, "h1", "Jobs")
    assert has_element?(view, "#job-filter-chips")
  end

  test "URL filters narrow the board and stay shareable", %{conn: conn} do
    poster = poster_fixture()
    publish_job!(poster, %{"title" => "Elixir Engineer", "required_tags" => "Elixir"})
    publish_job!(poster, %{"title" => "Java Developer", "required_tags" => "Java"})

    {:ok, _view, html} = live(conn, ~p"/jobs?#{[q: "Elixir"]}")

    assert html =~ "Elixir Engineer"
    refute html =~ "Java Developer"
  end

  test "a comma OR search matches either title (issue #952)", %{conn: conn} do
    poster = poster_fixture()
    publish_job!(poster, %{"title" => "Elixir Engineer"})
    publish_job!(poster, %{"title" => "Java Developer"})

    {:ok, _view, html} = live(conn, ~p"/jobs?#{[q: "Elixir, Java"]}")

    assert html =~ "Elixir Engineer"
    assert html =~ "Java Developer"
  end

  test "a prefix wildcard search reaches word variants", %{conn: conn} do
    poster = poster_fixture()
    publish_job!(poster, %{"title" => "Elixir Engineer"})

    {:ok, _view, html} = live(conn, ~p"/jobs?#{[q: "Engine*"]}")

    assert html =~ "Elixir Engineer"
  end

  test "the search-tips help is on the board", %{conn: conn} do
    publish_job!()
    {:ok, view, _html} = live(conn, ~p"/jobs")

    assert has_element?(view, "details summary", "Search tips")
    assert render(view) =~ "Webentwickler, PHP-Entwickler"
  end

  test "with no postings at all the board is not a board", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/jobs")

    # A search box over an empty corpus promises a stock and disproves it in
    # the same view, so neither it nor the filter chips render.
    refute has_element?(view, "form[action='/jobs'] input[name='q']")
    refute has_element?(view, "#job-filter-chips")
    assert html =~ "Yours would be the first"
    # The way in stays, logged out included: whoever has a job to fill is who
    # this page exists for.
    assert has_element?(view, "a[href='/jobs/new']")
  end

  test "the empty board offers the members who said they are available", %{conn: conn} do
    seeker =
      insert(:activated_user,
        employment_status: "open",
        employment_status_visibility: "everyone",
        desired_workplace_types: ["remote"]
      )

    {:ok, view, html} = live(conn, ~p"/jobs")

    assert has_element?(view, "#seeker-#{seeker.id}")
    assert html =~ "Open to offers"
    assert html =~ "Who you would reach"
  end

  test "the empty board keeps a members-only availability from a logged-out visitor", %{
    conn: conn
  } do
    quiet =
      insert(:activated_user,
        employment_status: "looking",
        employment_status_visibility: "members"
      )

    {:ok, view, _html} = live(conn, ~p"/jobs")

    refute has_element?(view, "#seeker-#{quiet.id}")
  end

  test "the empty board names the fields members carry", %{conn: conn} do
    tag = insert(:tag, name: "Elixir", slug: "elixir")
    user = insert(:activated_user)
    insert(:user_tag, user: user, tag: tag)

    {:ok, view, html} = live(conn, ~p"/jobs")

    assert html =~ "What members here work on"
    assert has_element?(view, "a[href='/tags/elixir']", "Elixir")
  end

  test "the empty board speaks German to a German browser", %{conn: conn} do
    # Every string on this page is new, and `mix gettext.extract --merge`
    # fuzzy-fills a new msgid with the translation of whatever it resembles —
    # so the German render is asserted by name rather than trusted.
    insert(:activated_user, employment_status: "open", employment_status_visibility: "everyone")

    {:ok, _view, html} =
      conn
      |> put_req_header("accept-language", "de-DE,de;q=0.9")
      |> live(~p"/jobs")

    assert html =~ "Wen Sie hier erreichen"
    assert html =~ "stünde allein oben"
    assert html =~ "Offen für Angebote"
  end

  test "a filter that matches nothing keeps the board, it does not read as empty", %{conn: conn} do
    # The reach page is for somebody who arrived at the plain board. A visitor
    # who searched asked a question, and the answer is "nothing matched" plus a
    # way to clear it — even on a corpus that happens to be empty.
    {:ok, view, html} = live(conn, ~p"/jobs?#{[q: "elixir"]}")

    assert has_element?(view, "#job-filter-chips")
    refute html =~ "Yours would be the first"
    assert html =~ "No matching positions"
  end

  test "one published posting brings the board back", %{conn: conn} do
    publish_job!()

    {:ok, view, _html} = live(conn, ~p"/jobs")

    assert has_element?(view, "#job-filter-chips")
    refute has_element?(view, "[id^='seeker-']")
  end

  test "a signed-in member sees the tag- and salary-match chips", %{conn: conn} do
    publish_job!()
    {conn, user} = create_and_login_user(conn)
    # A stored minimum-salary expectation (#928) offers the "from my expectation"
    # prefill chip; every signed-in member gets the "Matches my tags" chip.
    user
    |> Ecto.Changeset.change(desired_salary_min: 60_000, desired_salary_currency: "EUR")
    |> Vutuv.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/jobs")

    assert has_element?(view, "a[href*='my_tags']", "Matches my tags")
    assert has_element?(view, "a[href*='salary_min=mine']")
  end

  test "a member likes a posting from the board without reload", %{conn: conn} do
    poster = poster_fixture()
    posting = publish_job!(poster, %{"title" => "Likeable role"})
    {conn, _user} = create_and_login_user(conn)

    {:ok, view, _html} = live(conn, ~p"/jobs")

    view
    |> element("button[phx-click='toggle_like'][phx-value-id='#{posting.id}']")
    |> render_click()

    assert Jobs.job_posting_engagement(posting, nil).likes == 1
  end

  test "a posting published while the board is open appears live", %{conn: conn} do
    poster = poster_fixture()
    {:ok, view, _html} = live(conn, ~p"/jobs")

    refute render(view) =~ "Just appeared"
    publish_job!(poster, %{"title" => "Just appeared"})

    assert render(view) =~ "Just appeared"
  end

  describe "tag filter (issue #951)" do
    setup do
      poster = poster_fixture()

      elixir =
        publish_job!(poster, %{"title" => "Elixir Engineer", "required_tags" => "Elixir, Phoenix"})

      java = publish_job!(poster, %{"title" => "Java Developer", "required_tags" => "Java"})
      %{elixir: elixir, java: java}
    end

    test "several tags OR: shows postings carrying any of them, each a removable pill", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, ~p"/jobs?#{[tag: "elixir,java"]}")

      assert html =~ "Elixir Engineer"
      assert html =~ "Java Developer"
      assert has_element?(view, "[data-active-tag='elixir']")
      assert has_element?(view, "[data-active-tag='java']")
    end

    test "a single ?tag= still works (backward compatible)", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/jobs?#{[tag: "elixir"]}")

      assert html =~ "Elixir Engineer"
      refute html =~ "Java Developer"
    end

    test "the free-text add_tag field folds a typed name into the tag list", %{conn: conn} do
      # On Elixir already; add "Java" by name -> both match, both pills show.
      {:ok, view, html} = live(conn, ~p"/jobs?#{[tag: "elixir", add_tag: "Java"]}")

      assert html =~ "Elixir Engineer"
      assert html =~ "Java Developer"
      assert has_element?(view, "[data-active-tag='java']")
    end

    test "an unknown add_tag value is dropped, not applied", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/jobs?#{[add_tag: "does-not-exist-xyz"]}")

      # No filter applied -> both postings still show.
      assert html =~ "Elixir Engineer"
      assert html =~ "Java Developer"
    end

    test "offers unselected result tags as one-tap suggestions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/jobs")

      assert has_element?(view, "[data-suggest-tag='elixir']")
      assert has_element?(view, "[data-suggest-tag='java']")
    end

    test "a selected tag drops out of the suggestions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/jobs?#{[tag: "elixir"]}")

      # Elixir is selected (so it is not suggested), Phoenix co-occurs on the
      # one matching posting and is offered as a refinement.
      refute has_element?(view, "[data-suggest-tag='elixir']")
      assert has_element?(view, "[data-suggest-tag='phoenix']")
    end
  end

  describe "salary field (#953)" do
    test "everyone gets a minimum-salary input, even logged out", %{conn: conn} do
      publish_job!()
      {:ok, view, _html} = live(conn, ~p"/jobs")
      assert has_element?(view, "input#job-salary-min[name='salary_min']")
    end

    test "a typed minimum salary narrows the board and stays shareable", %{conn: conn} do
      poster = poster_fixture()

      publish_job!(poster, %{
        "title" => "Pays well",
        "salary_min" => "70000",
        "salary_max" => "90000"
      })

      publish_job!(poster, %{
        "title" => "Pays little",
        "salary_min" => "30000",
        "salary_max" => "45000"
      })

      {:ok, _view, html} = live(conn, ~p"/jobs?#{[salary_min: "60000"]}")

      assert html =~ "Pays well"
      refute html =~ "Pays little"
      # The field echoes the shared figure so the URL is a faithful, shareable state.
      assert html =~ ~s(value="60000")
    end

    test "the 'from my expectation' chip never renders the private figure", %{conn: conn} do
      publish_job!()
      {conn, user} = create_and_login_user(conn)

      user
      |> Ecto.Changeset.change(desired_salary_min: 60_000, desired_salary_currency: "EUR")
      |> Vutuv.Repo.update!()

      {:ok, view, html} = live(conn, ~p"/jobs?#{[salary_min: "mine"]}")

      # The chip resolves against the stored expectation, but the raw figure is
      # never rendered and the number field is disabled (not seeded with it).
      refute html =~ "60000"
      assert has_element?(view, "input#job-salary-min[disabled]")
    end
  end

  describe "save search (#935)" do
    test "no save control without active filters", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, view, _html} = live(conn, ~p"/jobs")
      refute has_element?(view, "#jobs-save-search-button")
    end

    test "a member saves the current board filters as an alert", %{conn: conn} do
      publish_job!()
      {conn, user} = create_and_login_user(conn)
      {:ok, view, _html} = live(conn, ~p"/jobs?#{[q: "elixir"]}")

      assert has_element?(view, "#jobs-save-search-button")
      view |> element("#jobs-save-search-button") |> render_click()

      view |> form("#jobs-save-search-form", %{notify: "daily"}) |> render_submit()

      assert [search] = Vutuv.SavedSearches.list_for_user(user).entries
      assert search.kind == :jobs
      assert search.notify == :daily
      assert search.query =~ "elixir"
    end
  end
end
