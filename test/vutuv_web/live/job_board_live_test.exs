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
    {:ok, view, _html} = live(conn, ~p"/jobs")

    assert has_element?(view, "details summary", "Search tips")
    assert render(view) =~ "Webentwickler, PHP-Entwickler"
  end

  test "shows an empty state with no postings", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/jobs")
    assert html =~ "No job postings yet"
  end

  test "a signed-in member sees the tag- and salary-match chips", %{conn: conn} do
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
