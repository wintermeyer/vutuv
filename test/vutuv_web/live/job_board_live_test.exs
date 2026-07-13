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
end
