defmodule VutuvWeb.FeedNewMarkerTest do
  @moduledoc """
  What the feed leaves standing after the "new posts" pill was pressed.

  Until now the press was a flash and nothing else: the waiting rows faded in
  over 200 ms and afterwards the column looked like any other minute of the
  day. Two marks answer what that left open. The **seam** is a line saying
  where the list ended when this page was opened, so it sits above the post
  that was newest at mount and **never moves** for the rest of the visit: a
  second batch lands above it, not below. The **dot** is per card and means
  "you have not looked at this one yet", so it is set in the browser by the
  same click that reveals the rows and taken off again by the reader's own
  eyes. Nothing here can test that second half, which is why the assertions
  below are on the rendered command rather than on a class.

  The seam moving is the mistake this file exists to catch. It is the obvious
  implementation — draw the line under the batch you just revealed — and it
  turns the one durable landmark on the page into a second copy of the dot.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  import Vutuv.PostsHelpers

  alias Vutuv.Social

  # A member the viewer follows, so anything they write reaches this feed.
  defp followed_author(viewer) do
    author = insert(:activated_user)
    Social.follow(viewer, author.id)
    author
  end

  defp seam_in?(view, %{id: post_id}) do
    has_element?(view, "#feed-post-#{post_id} [data-feed-seam]")
  end

  # The pill's `phx-click` is a JS command, and the browser is the only one who
  # runs it — so the mark it stamps can only be read out of the command itself.
  # Decoded rather than matched as a substring: `remove_attr` is in there either
  # way (it takes `hidden` off), and a test that cannot tell the two operations
  # apart would pass for an implementation that sweeps every older mark away.
  defp click_ops(view, selector) do
    [raw] =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("phx-click")

    Jason.decode!(raw)
  end

  defp sets_attr?(ops, name) do
    Enum.any?(ops, &match?(["set_attr", %{"attr" => [^name, _]}], &1))
  end

  defp removes_attr?(ops, name) do
    Enum.any?(ops, &match?(["remove_attr", %{"attr" => ^name}], &1))
  end

  describe "the seam" do
    test "is not drawn before anything has been revealed", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = followed_author(user)
      create_post!(author, %{body: "already on the page"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      refute has_element?(view, "[data-feed-seam]")
    end

    test "lands above the post that was newest when the page opened", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = followed_author(user)
      at_mount = create_post!(author, %{body: "already on the page"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      arrived = create_post!(author, %{body: "arrived while reading"})
      render_click(view, "show-new")

      assert seam_in?(view, at_mount)
      refute seam_in?(view, arrived)
    end

    test "does not move when a second batch is revealed", %{conn: conn} do
      # The calibration: an implementation that draws the line under the batch
      # it just revealed passes every assertion above and fails here.
      {conn, user} = create_and_login_user(conn)
      author = followed_author(user)
      at_mount = create_post!(author, %{body: "already on the page"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      first = create_post!(author, %{body: "first batch"})
      render_click(view, "show-new")

      second = create_post!(author, %{body: "second batch"})
      render_click(view, "show-new")

      assert seam_in?(view, at_mount)
      refute seam_in?(view, first)
      refute seam_in?(view, second)
    end

    test "is drawn exactly once", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = followed_author(user)
      for n <- 1..3, do: create_post!(author, %{body: "older post #{n}"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      create_post!(author, %{body: "arrived while reading"})
      render_click(view, "show-new")

      assert length(elements(render(view), "[data-feed-seam]")) == 1
    end
  end

  describe "the unread dot" do
    test "the pill's own command marks the rows it reveals", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = followed_author(user)
      create_post!(author, %{body: "already on the page"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      create_post!(author, %{body: "arrived while reading"})

      assert view |> click_ops("#show-new-posts") |> sets_attr?("data-new-mark")
    end

    test "a second press leaves the first batch marked", %{conn: conn} do
      # "Unread", not "the batch you just fetched": a reader who did not look at
      # the first six posts still has not looked at them once three more arrive,
      # so the command must take no older mark off.
      {conn, user} = create_and_login_user(conn)
      author = followed_author(user)
      create_post!(author, %{body: "already on the page"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      create_post!(author, %{body: "first batch"})
      render_click(view, "show-new")
      create_post!(author, %{body: "second batch"})

      ops = click_ops(view, "#show-new-posts")

      assert sets_attr?(ops, "data-new-mark")
      refute removes_attr?(ops, "data-new-mark")
      # The one attribute it does take off, so the refute above is not vacuous.
      assert removes_attr?(ops, "hidden")
    end
  end
end
