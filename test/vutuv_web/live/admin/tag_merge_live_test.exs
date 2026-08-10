defmodule VutuvWeb.Admin.TagMergeLiveTest do
  @moduledoc """
  The tag merge screen (`/admin/tags` → "Merge tags", issue #1338): admins only,
  pick two tags, see what the merge would move before confirming, do it, and
  take it back from the history below.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Tags.Merge
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag

  defp tag(name) do
    insert(:tag, name: name, slug: Vutuv.SlugHelpers.gen_slug_unique(name, Tag, :slug))
  end

  describe "authorization" do
    test "non-admins are locked out", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert html_response(get(conn, ~p"/admin/tag_merges"), 403)
    end
  end

  describe "merging" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)

      %{
        conn: conn,
        admin: admin,
        canonical: tag(unique_tag_name("Ruby on Rails")),
        absorbed: tag(unique_tag_name("rubyonrails"))
      }
    end

    test "shows what the merge would move before it is confirmed", ctx do
      insert(:user_tag, user: insert(:activated_user), tag: ctx.absorbed)

      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")

      pick(lv, ctx.absorbed, "absorbed")
      html = pick(lv, ctx.canonical, "canonical")

      assert has_element?(lv, "#merge-preview")
      assert html =~ "profiles carrying the tag"
      # Nothing has happened yet: the preview is a promise, not a receipt.
      assert is_nil(Repo.get!(Tag, ctx.absorbed.id).merged_into_id)
    end

    test "merging moves the rows and files the absorbed name", ctx do
      user_tag = insert(:user_tag, user: insert(:activated_user), tag: ctx.absorbed)

      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      pick(lv, ctx.absorbed, "absorbed")
      pick(lv, ctx.canonical, "canonical")

      lv |> element("#do-merge") |> render_click()

      assert Repo.get!(UserTag, user_tag.id).tag_id == ctx.canonical.id
      assert Repo.get!(Tag, ctx.absorbed.id).merged_into_id == ctx.canonical.id
      assert has_element?(lv, "#merge-history")
    end

    test "a refused pair says why, in place of the button", ctx do
      c = tag("c")
      cpp = tag("c++")

      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      pick(lv, cpp, "absorbed")
      html = pick(lv, c, "canonical")

      # The #1337 bucket: four languages one normalization would fold into one.
      assert html =~ "differ only in characters"
      refute has_element?(lv, "#do-merge")
    end

    test "the German screen is German", ctx do
      # A screen whose new labels were never checked in German ships whatever
      # the extract guessed, and the extract guesses badly: this page's
      # "Reverted" came back as "Geprüft" (checked) before it was written out.
      {:ok, _lv, html} =
        ctx.conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> live(~p"/admin/tag_merges")

      assert html =~ "Tags zusammenlegen"
      assert html =~ "Tag, das aufgenommen wird"
      assert html =~ "Tag, das bleibt"
      refute html =~ "Tag to absorb"
    end

    test "a merge can be reverted from the history", ctx do
      user_tag = insert(:user_tag, user: insert(:activated_user), tag: ctx.absorbed)
      {:ok, merge} = Merge.merge(ctx.absorbed, ctx.canonical, actor: ctx.admin)

      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      lv |> element("#merge-#{merge.id} button", "Revert") |> render_click()

      assert Repo.get!(UserTag, user_tag.id).tag_id == ctx.absorbed.id
      assert is_nil(Repo.get!(Tag, ctx.absorbed.id).merged_into_id)
    end

    test "a pair can be marked as different topics", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      pick(lv, ctx.absorbed, "absorbed")
      pick(lv, ctx.canonical, "canonical")

      lv |> element("#mark-distinct") |> render_click()

      assert Merge.distinct?(ctx.absorbed, ctx.canonical)
      # And the merge is refused from now on, whoever tries it.
      assert {:error, :marked_distinct} =
               Merge.merge(ctx.absorbed, ctx.canonical, actor: ctx.admin)
    end
  end

  describe "alternative names" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin, canonical: tag(unique_tag_name("Ruby on Rails"))}
    end

    test "a name nobody has typed yet can be filed pre-emptively", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      pick(lv, ctx.canonical, "canonical")

      name = unique_tag_name("ROR")
      lv |> form("#add-alias", %{"name" => name}) |> render_submit()

      # Typing it now attaches the topic instead of minting a second page.
      assert Tag.find_by_value(name).id == ctx.canonical.id
    end

    test "a name that is already a tag has to be merged instead", ctx do
      existing = tag(unique_tag_name("rails"))

      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      pick(lv, ctx.canonical, "canonical")

      html = lv |> form("#add-alias", %{"name" => existing.name}) |> render_submit()

      assert html =~ "Merge it instead"
      assert is_nil(Repo.get!(Tag, existing.id).merged_into_id)
    end
  end

  # Search for a tag and click its result, the way an admin picks one.
  defp pick(lv, tag, side) do
    lv |> form("#search-#{side}", %{"side" => side, "q" => tag.name}) |> render_change()

    lv |> element("#pick-#{side}-#{tag.id}") |> render_click()
  end
end
