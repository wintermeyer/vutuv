defmodule VutuvWeb.FeedTimelineResetTest do
  @moduledoc """
  What must be true every time the feed throws its timeline away and loads
  another one (issue #1870).

  There are three such moments — the mount, a source-filter change, and
  travelling to a day — and each used to spell the same ten assignments out by
  hand. The cost was not the repetition: it was that a fact about "the list on
  screen" could be added to two of them and forgotten in the third, with
  nothing failing. That had already happened once when this was written. Every
  path that puts entries on screen asks for their translations — the mount,
  "Load more", the day traveller — **except** the source switch, so a reader
  with auto-translate on who switched to the Fediverse sources (where the
  foreign-language posts are) got a page of untranslated cards until they
  reloaded.

  So these tests are about the paths agreeing, not about any one of them. They
  are the reason `replace_timeline/3` exists; if a fourth path is ever added,
  add it here.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers

  alias Vutuv.Accounts.User
  alias Vutuv.Posts
  alias Vutuv.Social
  alias Vutuv.Translations.TranslationJob
  alias Vutuv.ViewerClock

  defp followed_author(viewer) do
    author = insert(:activated_user)
    Social.follow(viewer, author.id)
    author
  end

  # Switch the reader's sources the way the filter band does: write the column,
  # then hand the feed the member it was written to (the shape
  # `feed_source_tabs_test.exs` established).
  defp switch(view, user, filter) do
    :ok = Posts.remember_feed_filter(user, filter, Repo.get!(User, user.id).feed_source)
    send(view.pid, {:filter_band, :changed, Repo.get!(User, user.id)})
    render(view)
  end

  defp translate_mode!(user) do
    user
    |> Ecto.Changeset.change(%{feed_foreign_posts: "translate"})
    |> Repo.update!()
  end

  describe "a source switch" do
    test "asks for the translations of the page it loads", %{conn: conn} do
      # The regression the chokepoint was built for. Calibrate it by taking
      # `auto_translate_entries/2` back out of `replace_timeline/3`, and the
      # last two assertions go red on their own.
      {conn, user} = create_and_login_user(conn)
      translate_mode!(user)
      author = followed_author(user)
      create_post!(author, %{body: "Already in the reader's language.", language: "en"})

      {:ok, view, _html} = live(conn, ~p"/feed")
      assert Repo.all(TranslationJob) == []

      # Written after the mount, so the socket's own `post_translations` map has
      # never seen it — deleting queued rows instead would prove nothing, since
      # that map remembers what it asked for and would not ask twice.
      #
      # The empty assertion below pins today's behaviour and is NOT an
      # endorsement of it: `queue/1` streams an arriving row into the timeline
      # and watches its photos without ever asking for its translation, so a
      # foreign-language post that arrives live stays untranslated even after
      # the reader presses the pill. That is the same gap one layer down, and it
      # is its own issue — the moment to translate an arrival (on arrival, or
      # when the reader reveals it) is a decision this refactor should not make.
      foreign = create_post!(author, %{body: "Ein fremdsprachiger Beitrag.", language: "de"})
      # `render/1` first, or this asserts against a LiveView that has not yet
      # handled the arrival and would pass however the arrival path behaves.
      render(view)
      assert Repo.all(TranslationJob) == []

      switch(view, user, :vutuv)

      assert [job] = Repo.all(TranslationJob)
      assert job.post_id == foreign.id
    end

    test "puts the visit boundary back on the list it just loaded", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = followed_author(user)
      create_post!(author, %{body: "on the page at mount"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      create_post!(author, %{body: "arrived while reading"})
      render_click(view, "show-new")
      assert has_element?(view, "[data-feed-seam]")

      # A different timeline: "what I did not have when I got here" is about to
      # mean something else, so the line goes until something is revealed again.
      switch(view, user, :vutuv)

      refute has_element?(view, "[data-feed-seam]")
    end
  end

  describe "travelling to a day" do
    test "puts the visit boundary back on the list it just loaded", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = followed_author(user)
      create_post!(author, %{body: "on the page at mount"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      create_post!(author, %{body: "arrived while reading"})
      render_click(view, "show-new")
      assert has_element?(view, "[data-feed-seam]")

      render_click(view, "cal-day", %{"date" => Date.to_iso8601(ViewerClock.today())})

      refute has_element?(view, "[data-feed-seam]")
    end
  end
end
