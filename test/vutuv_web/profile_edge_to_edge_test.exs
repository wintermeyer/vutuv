defmodule VutuvWeb.ProfileEdgeToEdgeTest do
  @moduledoc """
  The profile on a phone: every card runs from one edge of the screen to the
  other, and nothing but the section titles separates two of them.

  A 390px phone spent 40px before a profile's first word (16px page gutter +
  24px card padding), and the Posts card nested its pinned post in a second box
  that took another 16px on each side. Below `md` the page now cancels the
  gutter, every card keeps only a gutter's worth of padding, the Posts card runs
  like the feed's own timeline, and there is no band, line or shadow between two
  cards: each section's own title opens it. Chosen from a demo of seven
  transitions (2026-09-18); the rules live in the phone block of `app.css`.

  The header lost a row on the way: the vCard, bookmark and like glyphs ride the
  end of the counts line, which on a phone gives up the connections count to
  make room for them.

  Like `feed_edge_to_edge_test.exs`, this checks both ends of an attribute
  contract — the markers are where the selectors expect them, and the selectors
  are still there — reading the stylesheet with its comments stripped, since the
  prose names every selector too.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Posts

  @app_css Path.expand("../../assets/css/app.css", __DIR__)

  describe "the markup" do
    test "the page, its header and every card carry the markers", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      member = insert_activated_user()
      {:ok, _post} = Posts.create_post(member, %{body: "Ein Beitrag auf dem Profil."})

      html = conn |> get(~p"/#{member}") |> html_response(200)

      assert [grid] = elements(html, "[data-profile-edge]"),
             "The page's grid is what cancels the page gutter below `md`."

      refute attribute(grid, "class") =~ ~r/(^|\s)(gap|pt|py)-/,
             "No gap between two cards and no padding above the cover below `md`: " <>
               "nothing but the next card's title separates two sections there."

      assert [_] =
               elements(html, "[data-profile-header] [data-cover-frame].rounded-t-\\[inherit\\]"),
             "The cover takes the header's corners, so it squares with it on a phone."

      assert [_] = elements(html, "[data-profile-header] [data-profile-header-body]")

      assert [_] = elements(html, "[data-profile-edge] section#profile-posts[data-card]"),
             "`<.card>` stamps `data-card`, which is what the profile's phone rule keys on."
    end

    test "the Posts card runs like the feed's timeline, pinned post included", %{conn: conn} do
      member = insert_activated_user()
      {:ok, pinned} = Posts.create_post(member, %{body: "Der angeheftete Beitrag."})
      {:ok, _other} = Posts.create_post(member, %{body: "Ein zweiter Beitrag."})
      {:ok, _} = Posts.pin_to_profile(member, pinned)

      html = conn |> get(~p"/#{member}") |> html_response(200)

      assert [_] = elements(html, "#profile-posts[data-timeline-flush] > [data-timeline-rows]"),
             "The rows container has to be the flush card's direct child: that is how " <>
               "`app.css` hands the card's side padding to each row."

      assert [_] = elements(html, "#profile-posts[data-timeline-flush] > [data-pinned-post]"),
             "On a phone the pinned post is a full-width band, which the stylesheet finds " <>
               "as a direct child of the flush card."
    end

    test "the three glyphs ride the counts line", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      member = insert_activated_user()

      html = conn |> get(~p"/#{member}") |> html_response(200)

      for id <- ~w(download-vcard profile-bookmark profile-like) do
        assert [_] = elements(html, "#profile-counts ##{id}"),
               "`##{id}` belongs at the end of the counts line."
      end
    end

    test "below md the connections leave the counts line, whose weights still add up",
         %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)
      member = insert_activated_user()
      insert(:follow, follower: viewer, followee: member)
      insert(:follow, follower: member, followee: viewer)

      html = conn |> get(~p"/#{member}") |> html_response(200)

      assert [_] = elements(html, "#profile-connections.max-md\\:hidden.shrink-\\[10000\\]")

      assert [_] = elements(html, ~s(#profile-counts a[href$="/followers"].shrink-\\[100\\])),
             "Hiding the connections takes their weight with them. Left with two links " <>
               "at 0.01, flex hands out only the 2 % of the shortfall their weights add " <>
               "up to, and the line runs past the card edge instead of shortening a " <>
               "word (measured: 12px at 390px with the chip)."

      assert [_] = elements(html, ~s(#profile-counts a[href$="/following"].shrink)),
             "The last weight is a whole 1, so whichever links are left, the weights " <>
               "add up to at least 1 and the line always gives way (a 320px phone with " <>
               "the chip overflowed by 16px without it)."
    end
  end

  describe "the stylesheet" do
    test "has a rule for every marker, inside the phone block" do
      css = app_css()
      {phone, _} = :binary.match(css, "@media (width < 48rem) {")

      for selector <- [
            "[data-timeline-flush],\n  [data-profile-edge] {",
            "[data-timeline-flush] > :not([data-timeline-rows]) {",
            "[data-profile-edge] {",
            "[data-profile-edge] :is([data-card], [data-profile-header], [data-profile-band]) {",
            "[data-profile-edge] [data-card] {",
            "[data-profile-edge] [data-profile-band] {",
            "[data-profile-edge] [data-profile-header-body] {",
            "[data-profile-edge] [data-timeline-flush] {",
            "[data-profile-edge] [data-timeline-flush] > [data-pinned-post] {"
          ] do
        assert {at, _} = :binary.match(css, selector),
               "`assets/css/app.css` has lost the rule for `#{selector}`."

        assert at > phone, "`#{selector}` must sit in the phone block, below `md`."
      end
    end

    test "draws nothing between two cards" do
      refute app_css() =~ ~r/\[data-profile-edge\] \[data-card\] \{[^}]*border/,
             "No line between two cards; each section's title opens it."
    end

    test "cancels the same gutter the page pads with" do
      assert app_css() =~
               ~r/\[data-profile-edge\] \{[^}]*--flush-gutter-left: max\(1rem, env\(safe-area-inset-left\)\);/
    end
  end

  # Comments name every selector in this block, so an assertion against the raw
  # file would pass on a stylesheet that kept the prose and lost the rules.
  defp app_css, do: Regex.replace(~r{/\*.*?\*/}s, File.read!(@app_css), "")
end
