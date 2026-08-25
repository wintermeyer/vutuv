defmodule VutuvWeb.Admin.TagMergeLiveTest do
  @moduledoc """
  The tag merge screen (`/admin/tag_merges`, issue #1338): admins only. Collect
  the tags that mean one topic over as many searches as it takes, drop the ones
  that do not belong, pick which survives, see what the merge would move before
  confirming, and take any of it back from the history below.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Tags.Assistant
  alias Vutuv.Tags.Merge
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag

  defp tag(name) do
    insert(:tag, name: name, slug: Vutuv.SlugHelpers.gen_tag_slug_unique(name, Tag, :slug))
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

    test "the page shows what a merge does before anything is picked", ctx do
      # The screen was reported as not explaining itself: two column headings
      # and no way to tell which of the two names disappears.
      {:ok, lv, html} = live(ctx.conn, ~p"/admin/tag_merges")

      assert has_element?(lv, "#merge-example")
      assert html =~ "/tags/rubyonrails"
      assert html =~ "/tags/ruby_on_rails"
    end

    test "a search result names the address and the profile count, not just the tag", ctx do
      # Three spellings of one topic look identical by name alone; the number
      # of profiles is usually what decides which one survives.
      insert(:user_tag, user: insert(:activated_user), tag: ctx.canonical)

      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")

      html =
        lv
        |> form("#tag-search", %{"q" => ctx.canonical.name})
        |> render_change()

      assert html =~ "/tags/#{ctx.canonical.slug}"
      assert html =~ "1 profile"
    end

    test "which tag survives is chosen in the list, not by the order of picking", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      add(lv, ctx.absorbed)
      add(lv, ctx.canonical)

      # The first one added is the keeper until somebody says otherwise, and
      # saying otherwise is one click on the row.
      html = lv |> element("#basket-#{ctx.canonical.id} input[type=radio]") |> render_click()

      assert html =~ "#{ctx.absorbed.name} becomes an alternative name for #{ctx.canonical.name}"
    end

    test "a tag that does not belong can be taken back out", ctx do
      # The reported case: searching "rails" also finds "grails", a different
      # topic, and there was no way to drop it again.
      grails = tag(unique_tag_name("grails"))

      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      add(lv, ctx.canonical)
      add(lv, grails)
      assert has_element?(lv, "#basket-#{grails.id}")

      lv |> element("#remove-#{grails.id}") |> render_click()

      # Out of the list, but still findable: removing it says "not this topic",
      # not "never show me this tag".
      refute has_element?(lv, "#basket-#{grails.id}")
      assert has_element?(lv, "#basket-#{ctx.canonical.id}")
    end

    test "a tag the search cannot reach is collected by searching for it", ctx do
      # "ROR" never turns up under "rails", which is exactly why the screen
      # collects across searches instead of filling two slots from one.
      ror = tag(unique_tag_name("ROR"))

      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      add(lv, ctx.canonical)
      add(lv, ctx.absorbed)
      add(lv, ror)

      assert has_element?(lv, "#basket-#{ror.id}")

      lv |> element("#do-merge") |> render_click()

      assert Repo.get!(Tag, ror.id).merged_into_id == ctx.canonical.id
      assert Repo.get!(Tag, ctx.absorbed.id).merged_into_id == ctx.canonical.id
    end

    test "several tags are absorbed in one go, each revertible on its own", ctx do
      other = tag(unique_tag_name("rails"))
      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      add(lv, ctx.canonical)
      add(lv, ctx.absorbed)
      add(lv, other)

      lv |> element("#do-merge") |> render_click()

      assert Repo.get!(Tag, ctx.absorbed.id).merged_into_id == ctx.canonical.id
      assert Repo.get!(Tag, other.id).merged_into_id == ctx.canonical.id
      assert length(Merge.history()) == 2
    end

    test "the preview says in words what pressing merge would do", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      collect(lv, ctx.absorbed, ctx.canonical)
      html = render(lv)

      assert html =~ "#{ctx.absorbed.name} becomes an alternative name for #{ctx.canonical.name}"
      assert html =~ "/tags/#{ctx.absorbed.slug}"
      assert has_element?(lv, "#merge-sentence")
    end

    test "shows what the merge would move before it is confirmed", ctx do
      insert(:user_tag, user: insert(:activated_user), tag: ctx.absorbed)

      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")

      collect(lv, ctx.absorbed, ctx.canonical)
      html = render(lv)

      assert has_element?(lv, "#merge-preview")
      assert html =~ "profiles carrying the tag"
      # Nothing has happened yet: the preview is a promise, not a receipt.
      assert is_nil(Repo.get!(Tag, ctx.absorbed.id).merged_into_id)
    end

    test "merging moves the rows and files the absorbed name", ctx do
      user_tag = insert(:user_tag, user: insert(:activated_user), tag: ctx.absorbed)

      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      collect(lv, ctx.absorbed, ctx.canonical)

      lv |> element("#do-merge") |> render_click()

      assert Repo.get!(UserTag, user_tag.id).tag_id == ctx.canonical.id
      assert Repo.get!(Tag, ctx.absorbed.id).merged_into_id == ctx.canonical.id
      assert has_element?(lv, "#merge-history")
    end

    test "a refused pair says why, in place of the button", ctx do
      c = tag("c")
      cpp = tag("c++")

      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      collect(lv, cpp, c)
      html = render(lv)

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
      assert html =~ "Sammeln Sie die Tags"
      assert html =~ "Wählen Sie das Tag, das bleibt"
      assert html =~ "Vorschläge"
      assert html =~ "Ein Beispiel"
      assert html =~ "Nach der Zusammenlegung"
      # The example's counts go through the plural formatter, which the extract
      # had fuzzy-filled with "%{formatted} Likes".
      assert html =~ "89 Profile"
      refute html =~ "Tag to absorb"
      refute html =~ "Look for proposals"
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
      collect(lv, ctx.absorbed, ctx.canonical)

      lv |> element("#mark-distinct") |> render_click()

      assert Merge.distinct?(ctx.absorbed, ctx.canonical)
      # And the merge is refused from now on, whoever tries it.
      assert {:error, :marked_distinct} =
               Merge.merge(ctx.absorbed, ctx.canonical, actor: ctx.admin)
    end
  end

  describe "the proposal queue" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "scanning lists pairs, and opening one loads it into the preview", ctx do
      a = tag("Ruby on Rails")
      b = tag("rubyonrails")
      insert(:user_tag, user: insert(:activated_user), tag: a)

      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      html = lv |> element("#scan-candidates") |> render_click()

      assert html =~ "Ruby on Rails"
      assert [candidate] = Assistant.queue()

      # Opening a proposal does not merge it: it loads the pair above, where the
      # preview says what a merge would move.
      lv |> element("#candidate-#{candidate.id} button", "Review") |> render_click()

      assert has_element?(lv, "#merge-preview")
      assert is_nil(Repo.get!(Tag, b.id).merged_into_id)
    end

    test "rejecting a proposal records the pair as different topics", ctx do
      a = tag("Ruby on Rails")
      b = tag("rubyonrails")
      Assistant.scan(judge: false)
      [candidate] = Assistant.queue()

      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      lv |> element("#candidate-#{candidate.id} button", "Different topics") |> render_click()

      assert Assistant.queue() == []
      assert Merge.distinct?(a, b)
    end

    test "a merged pair leaves the queue", ctx do
      a = tag("Ruby on Rails")
      b = tag("rubyonrails")
      Assistant.scan(judge: false)
      assert [_] = Assistant.queue()

      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      collect(lv, b, a)
      lv |> element("#do-merge") |> render_click()

      assert Assistant.queue() == []
    end
  end

  describe "alternative names" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin, canonical: tag(unique_tag_name("Ruby on Rails"))}
    end

    test "a name nobody has typed yet can be filed pre-emptively", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      add(lv, ctx.canonical)

      name = unique_tag_name("ROR")
      lv |> form("#add-alias", %{"name" => name}) |> render_submit()

      # Typing it now attaches the topic instead of minting a second page.
      assert Tag.find_by_value(name).id == ctx.canonical.id
    end

    test "a name that is already a tag has to be merged instead", ctx do
      existing = tag(unique_tag_name("rails"))

      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")
      add(lv, ctx.canonical)

      html = lv |> form("#add-alias", %{"name" => existing.name}) |> render_submit()

      assert html =~ "Merge it instead"
      assert is_nil(Repo.get!(Tag, existing.id).merged_into_id)
    end

    # An open admin page outlives the rows it is showing: two admins on the same
    # queue, or one leaving a tab open while the alias is removed elsewhere. Every
    # other handler in this module answers a stale id with a flash; this one fed
    # the `Repo.get` miss straight to `Merge.remove_alias/1`, which has no nil
    # clause — so the socket went down with a FunctionClauseError and the page
    # simply vanished. Calibrated against the un-fixed code, where it crashes.
    test "removing an alias that is already gone says so instead of crashing", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")

      html = render_click(lv, "remove-alias", %{"id" => Vutuv.UUIDv7.generate()})

      assert html =~ "no longer" or html =~ "not"
      assert render(lv) =~ "tag"
    end

    test "and neither does a malformed one", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/tag_merges")

      render_click(lv, "remove-alias", %{"id" => "not-a-uuid"})

      assert render(lv) =~ "tag"
    end
  end

  # Search for a tag and add it to the list, the way an admin collects one.
  defp add(lv, tag) do
    lv |> form("#tag-search", %{"q" => tag.name}) |> render_change()
    lv |> element("#add-#{tag.id}") |> render_click()
  end

  # Collect a pair and say which of the two survives.
  defp collect(lv, absorbed, keeper) do
    add(lv, absorbed)
    add(lv, keeper)
    lv |> element("#basket-#{keeper.id} input[type=radio]") |> render_click()
  end
end
