defmodule VutuvWeb.TagNewLiveTest do
  @moduledoc """
  The add-tag form (/settings/tags/new) is a LiveView: while the member types
  it shows exactly which tags a submit will attach (issue #848). Only a comma
  separates, so a multi-word tag needs no quoting, and the shared `<.tag_input>`
  pill box makes that visible in the field itself. The server preview below it
  therefore speaks only where the outcome differs from what was typed: an
  existing tag matched case-insensitively contributes its own stored display
  name, and a name the save would refuse drops out. Submitting goes over the
  socket (the dead new/create controller actions are gone), so these tests also
  cover what user_tag_controller_test's create tests used to.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Tags.UserTag

  defp tag_count(user),
    do: Repo.aggregate(from(ut in UserTag, where: ut.user_id == ^user.id), :count)

  defp slugify(name), do: Vutuv.SlugHelpers.gen_tag_slug_unique(name, Vutuv.Tags.Tag, :slug)

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
      assert html =~ "Separate tags with a comma."
      # The tip moved above the input (issue #848, variant one): the hint
      # paragraph must come before the <input> in source order.
      {tip_at, _} = :binary.match(html, "Separate tags with a comma.")
      {input_at, _} = :binary.match(html, ~s(id="tag_param_value"))
      assert tip_at < input_at
    end

    test "renders the shared pill box around the field", %{live: live} do
      # The pills are built client-side inside this root, so what the server
      # owes is the widget root and the plain input the enhancement wraps.
      assert has_element?(live, "#tag-input[data-tag-input]")
      assert has_element?(live, "#tag-input input[data-tag-input-field]#tag_param_value")
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

    test "stays away while the pills already say the outcome", %{live: live} do
      # A fresh tag is stored exactly as typed, so a preview here would only
      # repeat the box back at the member.
      live
      |> form("#tag-form", tag_param: %{value: "WebAssembly, Ruby on Rails"})
      |> render_change()

      refute render(live) =~ ~s(id="tag-preview")
    end

    test "an existing tag previews with its stored display name", %{live: live} do
      # The motivating case of issue #848: tag names are matched
      # case-insensitively, so typing a camel-case variant of an existing
      # (typically lowercase) tag attaches that tag — the preview must show
      # the name the profile chip will actually display.
      insert(:tag, name: "ahmetsun", slug: "ahmetsun")
      insert(:tag, name: "CLAUDE", slug: "claude")

      assert preview(live, "AhmetSun, claude") == ["ahmetsun", "CLAUDE"]
      assert render(live) =~ "This will create the following tags:"
    end

    test "a space no longer splits, so a multi-word tag stays one chip", %{live: live} do
      insert(:tag, name: "ruby on rails", slug: "ruby_on_rails")

      assert preview(live, "Ruby on Rails") == ["ruby on rails"]
    end

    test "collapses case-insensitive duplicates into one chip", %{live: live} do
      insert(:tag, name: "PHP", slug: "php")

      assert preview(live, "php, PHP, php") == ["PHP"]
    end

    test "clearing the input removes the preview again", %{live: live} do
      insert(:tag, name: "elixir", slug: "elixir")
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

    test "adds several comma-separated tags at once", %{
      live: live,
      user: user,
      base: base
    } do
      live
      |> form("#tag-form", tag_param: %{value: "Elixir, Phoenix, Ruby on Rails"})
      |> render_submit()

      flash = assert_redirect(live, ~p"/settings/tags")
      assert flash["info"] == "Added 3 tags."
      assert tag_count(user) == base + 3
    end

    test "submits what the preview showed: duplicates collapse first", %{
      live: live,
      user: user,
      base: base
    } do
      # "php, PHP" is one tag, so the submit must attach one — not report the
      # second spelling as a failed duplicate.
      live |> form("#tag-form", tag_param: %{value: "php, PHP"}) |> render_submit()

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
      # The banner promises a field marked in red, so there has to be one: this
      # branch used to raise it off an errorless changeset.
      assert html =~ "Please type at least one tag."
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
      # Duplicates and invalid names keep their own sentence; the ceiling has
      # one of its own (issue #1478), so neither reason speaks for the other.
      assert flash["info"] == "Added 1 tag. Skipped 1 tag that is a duplicate or invalid."
      assert tag_count(user) == base + 2
    end

    test "attaches the topic once when both of its names are typed", %{
      live: live,
      user: user,
      base: base
    } do
      # An alternative name (issue #1338) resolves to its topic, so typing both
      # names is naming one tag twice — which a member cannot see, the two
      # spellings looking nothing alike. The batch must collapse to the one tag
      # instead of reporting its second half as a failed duplicate.
      canonical_name = unique_tag_name("Ruby on Rails")
      canonical = insert(:tag, name: canonical_name, slug: slugify(canonical_name))
      abbreviation = unique_tag_name("ROR")

      insert(:tag,
        name: abbreviation,
        slug: slugify(abbreviation),
        merged_into_id: canonical.id,
        alias_kind: "abbreviation"
      )

      live
      |> form("#tag-form", tag_param: %{value: "#{abbreviation}, #{canonical_name}"})
      |> render_submit()

      flash = assert_redirect(live, ~p"/settings/tags")
      assert flash["info"] == "User tag created successfully."
      assert tag_count(user) == base + 1
    end

    test "previews no chip for a name the save would refuse", %{live: live} do
      # The preview's promise is "these tags will be created", so it must not
      # offer one add_user_tag/2 turns down a moment later.
      assert preview(live, "https://www.example-shop.com/, Elixir") == ["Elixir"]
      assert preview(live, "???, Elixir") == ["Elixir"]
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

    test "shows the punctuation-only error inline instead of attaching the tag", %{
      live: live,
      user: user,
      base: base
    } do
      html = live |> form("#tag-form", tag_param: %{value: "???"}) |> render_submit()

      assert html =~ "must not be only punctuation"
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

    # The guard above only catches a profile that is ALREADY full. A batch that
    # runs into the ceiling half way through used to attach what fit and report
    # the rest as duplicates or invalid — the one reason a member cannot act on
    # (the same defect the LinkedIn import had, issue #1478).
    test "a batch that overruns the ceiling names the ceiling, not duplicates", %{
      live: live,
      user: user
    } do
      # Three registration tags plus these leaves room for exactly two more.
      for _ <- 1..(Vutuv.Tags.max_user_tags() - 3 - 2),
          do: insert(:user_tag, user: user, tag: build(:tag))

      names = for _ <- 1..5, do: unique_tag_name("Batch")

      live |> form("#tag-form", tag_param: %{value: Enum.join(names, ", ")}) |> render_submit()

      flash = assert_redirect(live, ~p"/settings/tags")

      assert flash["info"] ==
               "Added 2 tags. 3 tags did not fit: your profile holds at most 15. " <>
                 "Remove some and try again."

      refute flash["info"] =~ "duplicate"
      assert tag_count(user) == Vutuv.Tags.max_user_tags()
    end
  end
end
