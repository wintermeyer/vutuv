defmodule VutuvWeb.TagNewLiveTest do
  @moduledoc """
  The add-tag form (/settings/tags/new) is a LiveView: while the member types
  it previews exactly which tags a submit will attach (issue #848). An unquoted
  comma or space separates, a quoted phrase is one multi-word tag, a leading `#`
  is stripped, and each name is matched case-insensitively against the existing
  global tags, whose stored display name wins. Submitting goes over the socket
  (the dead new/create controller actions are gone), so these tests also cover
  what user_tag_controller_test's create tests used to.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Tags.UserTag

  defp tag_count(user),
    do: Repo.aggregate(from(ut in UserTag, where: ut.user_id == ^user.id), :count)

  # Type `value` into the form and return the previewed chip texts, in order.
  defp preview(live, value) do
    live
    |> form("#tag-form", tag_param: %{value: value})
    |> render_change()

    live
    |> element("#tag-preview")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-tag-chip]")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  test "redirects anonymous visitors instead of rendering the form", %{conn: conn} do
    conn = get(conn, ~p"/settings/tags/new")
    assert redirected_to(conn) == ~p"/"
  end

  describe "the form" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, html} = live(conn, ~p"/settings/tags/new")
      {:ok, live: live, html: html, user: user}
    end

    test "explains the separator rule as a tip above the input", %{html: html} do
      assert html =~ "Separate tags with a comma or a space."
      # The tip moved above the input (issue #848, variant one): the hint
      # paragraph must come before the <input> in source order.
      {tip_at, _} = :binary.match(html, "Separate tags with a comma or a space.")
      {input_at, _} = :binary.match(html, ~s(id="tag_param_value"))
      assert tip_at < input_at
    end

    test "shows no preview while nothing is typed", %{html: html} do
      refute html =~ ~s(id="tag-preview")
    end
  end

  describe "the live preview" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/settings/tags/new")
      {:ok, live: live, user: user}
    end

    test "splits the input on commas and spaces into one chip per tag", %{live: live} do
      assert preview(live, "lorem ipsum, dolor-sit") == ["lorem", "ipsum", "dolor-sit"]
      assert render(live) =~ "This will create the following tags:"
    end

    test "previews a quoted phrase as one multi-word chip", %{live: live} do
      assert preview(live, ~s(Elixir, "Ruby on Rails")) == ["Elixir", "Ruby on Rails"]
    end

    test "a brand-new tag previews exactly as typed", %{live: live} do
      # Display names keep the entered casing (only the slug is lowercased),
      # so the honest preview for a fresh tag is the typed spelling.
      assert preview(live, "WebAssembly") == ["WebAssembly"]
    end

    test "an existing tag previews with its stored display name", %{live: live} do
      # The motivating case of issue #848: tag names are matched
      # case-insensitively, so typing a camel-case variant of an existing
      # (typically lowercase) tag attaches that tag — the preview must show
      # the name the profile chip will actually display.
      insert(:tag, name: "ahmetsun", slug: "ahmetsun")
      insert(:tag, name: "CLAUDE", slug: "claude")

      assert preview(live, "AhmetSun claude") == ["ahmetsun", "CLAUDE"]
    end

    test "strips the leading # of the hashtag form", %{live: live} do
      assert preview(live, "#Elixir") == ["Elixir"]
    end

    test "collapses case-insensitive duplicates into one chip", %{live: live} do
      assert preview(live, "php PHP php") == ["php"]
    end

    test "clearing the input removes the preview again", %{live: live} do
      preview(live, "Elixir")

      live
      |> form("#tag-form", tag_param: %{value: "  "})
      |> render_change()

      refute render(live) =~ ~s(id="tag-preview")
    end
  end

  describe "submitting" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/settings/tags/new")
      {:ok, live: live, user: user, base: tag_count(user)}
    end

    test "adds a single tag and redirects to the tags page", %{
      live: live,
      user: user,
      base: base
    } do
      live |> form("#tag-form", tag_param: %{value: "Elixir"}) |> render_submit()

      flash = assert_redirect(live, ~p"/settings/tags")
      assert flash["info"] == "User tag created successfully."
      assert tag_count(user) == base + 1
    end

    test "adds several comma- or space-separated tags at once", %{
      live: live,
      user: user,
      base: base
    } do
      live |> form("#tag-form", tag_param: %{value: "Elixir, Phoenix  Ruby"}) |> render_submit()

      flash = assert_redirect(live, ~p"/settings/tags")
      assert flash["info"] == "Added 3 tags."
      assert tag_count(user) == base + 3
    end

    test "submits what the preview showed: duplicates collapse first", %{
      live: live,
      user: user,
      base: base
    } do
      # "php PHP" previews as one chip, so the submit must attach one tag —
      # not report the second spelling as a failed duplicate.
      live |> form("#tag-form", tag_param: %{value: "php PHP"}) |> render_submit()

      flash = assert_redirect(live, ~p"/settings/tags")
      assert flash["info"] == "User tag created successfully."
      assert tag_count(user) == base + 1
    end

    test "keeps the form with an error when nothing usable is typed", %{
      live: live,
      user: user,
      base: base
    } do
      html = live |> form("#tag-form", tag_param: %{value: " , "}) |> render_submit()

      assert html =~ "Please check the fields marked in red."
      assert tag_count(user) == base
    end

    test "shows the duplicate error inline for a single repeated tag", %{
      live: live,
      user: user,
      base: base
    } do
      {:ok, _} = Vutuv.Tags.add_user_tag(user, "Elixir")

      html = live |> form("#tag-form", tag_param: %{value: "elixir"}) |> render_submit()

      assert html =~ "You already have this tag."
      assert tag_count(user) == base + 1
    end

    test "counts the failures when part of a batch cannot be added", %{
      live: live,
      user: user,
      base: base
    } do
      {:ok, _} = Vutuv.Tags.add_user_tag(user, "Elixir")

      live |> form("#tag-form", tag_param: %{value: "Elixir, Phoenix"}) |> render_submit()

      flash = assert_redirect(live, ~p"/settings/tags")
      assert flash["info"] == "Added 1 of 2 tags (the rest were duplicates or invalid)."
      assert tag_count(user) == base + 2
    end

    test "previews no chip for a web address the save would refuse", %{live: live} do
      # The preview's promise is "these tags will be created", so it must not
      # offer one add_user_tag/2 turns down a moment later.
      assert preview(live, "https://www.example-shop.com/ Elixir") == ["Elixir"]
    end

    test "shows the web-address error inline instead of attaching a URL tag", %{
      live: live,
      user: user,
      base: base
    } do
      html =
        live
        |> form("#tag-form", tag_param: %{value: "https://www.example-shop.com/"})
        |> render_submit()

      assert html =~ "must not be a web or email address"
      assert tag_count(user) == base
    end

    test "refuses a new tag once the profile is at the tag limit", %{
      live: live,
      user: user
    } do
      # Fill the profile up to the cap (bypassing the form so we test its guard).
      for _ <- 1..Vutuv.Tags.max_user_tags(),
          do: insert(:user_tag, user: user, tag: build(:tag))

      full = tag_count(user)

      html = live |> form("#tag-form", tag_param: %{value: "OneMore"}) |> render_submit()

      # No redirect (the form stays put) and a clear message naming the ceiling.
      assert html =~ "at most"
      assert tag_count(user) == full
      refute Repo.exists?(from(t in Vutuv.Tags.Tag, where: t.name == "OneMore"))
    end
  end
end
