defmodule VutuvWeb.ComposerDraftTest do
  @moduledoc """
  The composer keeps what you typed (issue #1148).

  A reload rebuilds the page from nothing — LiveView's form recovery only runs
  on a socket *reconnect* — so the composer autosaves its content and reads it
  back when it opens. These tests reload by mounting the page a second time,
  which is what a browser reload amounts to on the server side.

  The draft debounce is 0 in the test env (`config/test.exs`), so the write
  happens inside the `validate` that changed something and there is no timer to
  race.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Posts
  alias Vutuv.Posts.PostDraft

  defp type(live, params) do
    live |> form("#composer-form", %{"post" => params}) |> render_change()
  end

  describe "the feed composer" do
    test "typing is autosaved and comes back after a reload", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")
      type(live, %{"body" => "Ein halber Gedanke", "tags" => "elixir"})

      assert %PostDraft{body: "Ein halber Gedanke", tags: "elixir"} = Posts.get_draft(user)

      # The reload.
      {:ok, _reloaded, html} = live(recycle(conn), ~p"/feed")

      assert html =~ "Ein halber Gedanke"
      assert html =~ "elixir"
    end

    test "a restored draft says so and the collapsed panel opens for it", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, html} = live(conn, ~p"/feed")
      # Nothing to restore yet: no notice, and the panel is still collapsed.
      refute html =~ "data-draft-restored"
      assert html =~ ~s(id="composer-panel" class="hidden")

      type(live, %{"body" => "Ein halber Gedanke"})

      {:ok, reloaded, html} = live(recycle(conn), ~p"/feed")

      assert has_element?(reloaded, "[data-draft-restored]")
      # Text behind a collapsed panel would read exactly like text that was
      # thrown away, so the feed opens the composer over a restored draft.
      refute html =~ ~s(id="composer-panel" class="hidden")
    end

    test "a restored draft shows exactly one Discard draft control", %{conn: conn} do
      # The restore notice carries its own "Discard draft" (issue #1148) and
      # the feed header shows one while there is something to lose (issue
      # #1135). After a reload both conditions held, so the composer rendered
      # the button twice, one right above the other (issue #1221). While the
      # notice shows, it owns the action; the header button takes over as soon
      # as the notice steps aside.
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")
      type(live, %{"body" => "Ein halber Gedanke"})

      {:ok, reloaded, _html} = live(recycle(conn), ~p"/feed")

      assert has_element?(reloaded, "[data-draft-restored] button[phx-click='discard-draft']")
      refute has_element?(reloaded, "#composer-discard")

      type(reloaded, %{"body" => "Ein halber Gedanke, weitergeschrieben"})

      refute has_element?(reloaded, "[data-draft-restored]")
      assert has_element?(reloaded, "#composer-discard")
    end

    test "the notice steps aside as soon as the member edits", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")
      type(live, %{"body" => "Ein halber Gedanke"})

      {:ok, reloaded, _html} = live(recycle(conn), ~p"/feed")
      assert has_element?(reloaded, "[data-draft-restored]")

      type(reloaded, %{"body" => "Ein halber Gedanke, weitergeschrieben"})

      refute has_element?(reloaded, "[data-draft-restored]")
    end

    test "the notice steps aside without restructuring the card around the form", %{conn: conn} do
      # The notice lives in a wrapper that is always rendered, so the card's
      # child list keeps its shape when the notice goes. With the `:if` on a
      # direct child of the card instead, morphdom relocates the form to put
      # the siblings back in order, and re-parenting the editor's
      # `contenteditable` blurs it: the caret is thrown out of the composer
      # mid-sentence and every keystroke after it is lost. Assert the wrapper
      # is there in both states so nobody folds it away as dead markup.
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, html} = live(conn, ~p"/feed")
      assert html =~ ~s(id="composer-notice")
      refute has_element?(live, "[data-draft-restored]")

      type(live, %{"body" => "Ein halber Gedanke"})

      {:ok, reloaded, _html} = live(recycle(conn), ~p"/feed")
      assert has_element?(reloaded, "#composer-notice [data-draft-restored]")

      html = type(reloaded, %{"body" => "Ein halber Gedanke, weitergeschrieben"})

      assert html =~ ~s(id="composer-notice")
      refute html =~ "data-draft-restored"
    end

    test "emptying the composer removes the draft", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")
      type(live, %{"body" => "Ein halber Gedanke"})
      assert Posts.get_draft(user)

      type(live, %{"body" => ""})

      assert Posts.get_draft(user) == nil
    end

    test "posting clears the draft, so the next reload opens empty", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")
      type(live, %{"body" => "Ein ganzer Gedanke"})
      assert Posts.get_draft(user)

      live
      |> form("#composer-form", %{"post" => %{"body" => "Ein ganzer Gedanke"}})
      |> render_submit()

      assert Posts.get_draft(user) == nil

      {:ok, _reloaded, html} = live(recycle(conn), ~p"/feed")
      refute html =~ "data-draft-restored"
    end

    test "Discard draft empties the composer and drops the stored draft", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")
      type(live, %{"body" => "Ein halber Gedanke"})

      {:ok, reloaded, _html} = live(recycle(conn), ~p"/feed")

      html =
        reloaded
        |> element("[data-draft-restored] button[phx-click='discard-draft']")
        |> render_click()

      assert Posts.get_draft(user) == nil
      refute html =~ "Ein halber Gedanke"
      refute has_element?(reloaded, "[data-draft-restored]")
    end

    test "the header's Discard button drops the stored draft too, not just the form", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")
      type(live, %{"body" => "Ein halber Gedanke"})
      assert Posts.get_draft(user)

      # Discard shares its handler with the restore notice's button — so it
      # has to take the stored draft with it, or the next visit would hand
      # back what was just thrown away.
      live |> element("#composer-discard") |> render_click()

      assert Posts.get_draft(user) == nil
    end

    test "one member's draft never reaches another's composer", %{conn: conn} do
      {conn, _author} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")
      type(live, %{"body" => "Ein halber Gedanke"})

      other_conn = build_conn() |> Plug.Test.init_test_session(%{})
      {other_conn, _other} = create_and_login_user(other_conn)
      {:ok, _other_live, html} = live(other_conn, ~p"/feed")

      refute html =~ "Ein halber Gedanke"
    end
  end

  describe "the reply page" do
    test "a reply draft is kept apart from the new-post draft", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = insert(:user, email_confirmed?: true)
      {:ok, parent} = Posts.create_post(author, %{body: "a passage worth answering"})

      {:ok, feed, _html} = live(conn, ~p"/feed")
      type(feed, %{"body" => "ein neuer Beitrag"})

      {:ok, reply, _html} = live(recycle(conn), ~p"/posts/#{parent.id}/reply")
      type(reply, %{"body" => "eine Antwort"})

      assert %PostDraft{body: "ein neuer Beitrag"} = Posts.get_draft(user)
      assert %PostDraft{body: "eine Antwort"} = Posts.get_draft(user, parent)

      {:ok, _reloaded, html} = live(recycle(conn), ~p"/posts/#{parent.id}/reply")
      assert html =~ "eine Antwort"
      refute html =~ "ein neuer Beitrag"
    end

    test "without a draft the quote from the URL still opens the composer", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      author = insert(:user, email_confirmed?: true)
      {:ok, parent} = Posts.create_post(author, %{body: "a passage worth answering"})

      {:ok, _live, html} =
        live(conn, ~p"/posts/#{parent.id}/reply?quote=a+passage+worth+answering")

      assert html =~ "a passage worth answering"
      refute html =~ "data-draft-restored"
    end

    test "discarding a reply draft falls back to the quote, not to nothing", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      author = insert(:user, email_confirmed?: true)
      {:ok, parent} = Posts.create_post(author, %{body: "a passage worth answering"})

      path = ~p"/posts/#{parent.id}/reply?quote=a+passage+worth+answering"

      {:ok, live, _html} = live(conn, path)
      type(live, %{"body" => "meine eigene Antwort"})

      {:ok, reloaded, html} = live(recycle(conn), path)
      assert html =~ "meine eigene Antwort"

      html =
        reloaded
        |> element("[data-draft-restored] button[phx-click='discard-draft']")
        |> render_click()

      refute html =~ "meine eigene Antwort"
      assert html =~ "a passage worth answering"
    end
  end

  describe "the edit page" do
    test "editing a published post neither stores nor restores a draft", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "as published"})

      {:ok, live, html} = live(conn, ~p"/posts/#{post.id}/edit")
      refute html =~ "data-draft-restored"

      type(live, %{"body" => "halb umgeschrieben"})

      # Restoring a weeks-old unsaved edit over text other people have already
      # read is a different promise from keeping a draft, so the edit page is
      # deliberately outside the system.
      assert Posts.get_draft(user) == nil
      assert Posts.get_draft(user, post) == nil

      {:ok, _reloaded, html} = live(recycle(conn), ~p"/posts/#{post.id}/edit")
      assert html =~ "as published"
      refute html =~ "halb umgeschrieben"
    end
  end
end
