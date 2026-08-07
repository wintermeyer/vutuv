defmodule VutuvWeb.SettingsAutoPostDeletionTest do
  @moduledoc """
  The /settings/auto_post_deletion page (issue #1255): the rule's form, the
  two-step confirmation, and the account-activity trail.

  The confirmation is the reason this page has a test of its own. It promises a
  member an exact number and then deletes, so what is asserted here is that the
  number comes from the same query the deletion runs, that nothing is deleted
  without it, and that a rule tightened later goes through it again.
  """

  use VutuvWeb.ConnCase, async: true

  import Vutuv.PostsHelpers

  alias Vutuv.AccountEvents
  alias Vutuv.Posts.Post

  defp aged_post!(author, days_old) do
    post = create_post!(author, %{body: "Old enough"})
    at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -days_old * 24 * 60 * 60)
    Repo.update_all(from(p in Post, where: p.id == ^post.id), set: [inserted_at: at])
    post
  end

  defp post_count(author) do
    Repo.aggregate(from(p in Post, where: p.user_id == ^author.id), :count)
  end

  defp kinds(user) do
    user |> AccountEvents.recent(50) |> Enum.map(& &1.kind)
  end

  # Everything the form submits, so a test can vary one value and keep the rest.
  defp rule(overrides \\ %{}) do
    Map.merge(
      %{
        "auto_post_deletion?" => "true",
        "auto_post_deletion_after_days" => "30",
        "auto_post_deletion_keep_photos?" => "true",
        "auto_post_deletion_keep_answered?" => "true",
        "auto_post_deletion_keep_bookmarked?" => "true",
        "auto_post_deletion_delete_replies?" => "false",
        "auto_post_deletion_min_likes" => "0",
        "auto_post_deletion_min_bookmarks" => "0",
        "auto_post_deletion_min_reposts" => "0"
      },
      overrides
    )
  end

  describe "the page" do
    test "renders the form, and it posts to the URL the router serves", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html = conn |> get(~p"/settings/auto_post_deletion") |> html_response(200)

      # The form's own action, not a route this test happens to know: a Save
      # button pointing at a retired URL is invisible to a hand-built PUT.
      assert html =~ ~s(action="/settings/auto_post_deletion")
      assert html =~ ~s(id="auto-post-deletion-form")
      assert html =~ ~s(name="user[auto_post_deletion_after_days]")
      assert html =~ ~s(name="user[auto_post_deletion_min_likes]")

      # The labels have to point at the ids the form really generated: the
      # form's own id prefixes them, so a hand-written for="user_…" would
      # silently address nothing.
      assert html =~ ~s(for="auto-post-deletion-form_auto_post_deletion_after_days")
    end

    test "says plainly that other servers cannot be forced to delete", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html = conn |> get(~p"/settings/auto_post_deletion") |> html_response(200)

      assert html =~ "We cannot make them."
      assert html =~ "cannot be undone"
    end

    test "is reachable from the settings hub", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      assert conn |> get(~p"/settings") |> html_response(200) =~
               ~s(href="/settings/auto_post_deletion")
    end

    test "needs a login", %{conn: conn} do
      conn = get(conn, ~p"/settings/auto_post_deletion")
      assert redirected_to(conn) == "/"
    end
  end

  describe "saving a rule with nothing to delete" do
    test "saves straight through, with no confirmation", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      fresh = create_post!(user, %{body: "Brand new"})

      conn = put(conn, ~p"/settings/auto_post_deletion", %{"user" => rule()})

      assert redirected_to(conn) == "/settings/auto_post_deletion"
      assert Repo.reload!(user).auto_post_deletion?
      assert Repo.exists?(from(p in Post, where: p.id == ^fresh.id))
      assert "auto_post_deletion_changed" in kinds(user)
      refute "posts_auto_deleted" in kinds(user)
    end
  end

  describe "the confirmation" do
    test "asks first and deletes nothing yet when posts would go now", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      aged_post!(user, 90)
      aged_post!(user, 90)

      conn = put(conn, ~p"/settings/auto_post_deletion", %{"user" => rule()})
      html = html_response(conn, 200)

      assert html =~ ~s(id="auto-post-deletion-confirm")
      assert html =~ "Delete 2 posts now?"

      # Nothing has happened yet: not the deletion, and not the save either.
      assert post_count(user) == 2
      refute Repo.reload!(user).auto_post_deletion?
      refute "auto_post_deletion_changed" in kinds(user)
      refute "posts_auto_deleted" in kinds(user)
    end

    test "saves and deletes once confirmed", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      aged_post!(user, 90)
      aged_post!(user, 90)
      keep = create_post!(user, %{body: "Brand new"})

      conn =
        put(conn, ~p"/settings/auto_post_deletion", %{
          "user" => rule(%{"confirmed" => "true"})
        })

      assert redirected_to(conn) == "/settings/auto_post_deletion"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "2 posts were deleted"

      assert Repo.reload!(user).auto_post_deletion?
      assert post_count(user) == 1
      assert Repo.exists?(from(p in Post, where: p.id == ^keep.id))

      assert "auto_post_deletion_changed" in kinds(user)
      assert "posts_auto_deleted" in kinds(user)
    end

    test "asks again when the rule is tightened later", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      aged_post!(user, 60)

      # A year keeps everything, so this first save goes through untroubled.
      conn =
        put(conn, ~p"/settings/auto_post_deletion", %{
          "user" => rule(%{"auto_post_deletion_after_days" => "365"})
        })

      assert redirected_to(conn) == "/settings/auto_post_deletion"
      assert post_count(user) == 1

      # Shortening it is exactly as destructive as switching it on was.
      conn = put(conn, ~p"/settings/auto_post_deletion", %{"user" => rule()})

      assert html_response(conn, 200) =~ ~s(id="auto-post-deletion-confirm")
      assert post_count(user) == 1
    end

    test "carries the submitted rule into the confirmation form", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      aged_post!(user, 90)

      conn =
        put(conn, ~p"/settings/auto_post_deletion", %{
          "user" => rule(%{"auto_post_deletion_keep_photos?" => "false"})
        })

      html = html_response(conn, 200)

      assert html =~ ~s(name="user[auto_post_deletion_keep_photos?]" value="false")
      assert html =~ ~s(name="user[confirmed]" value="true")
    end
  end

  describe "validation" do
    test "refuses the switch without an age", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        put(conn, ~p"/settings/auto_post_deletion", %{
          "user" => rule(%{"auto_post_deletion_after_days" => ""})
        })

      assert html_response(conn, 422) =~ "auto-post-deletion-form"
      refute Repo.reload!(user).auto_post_deletion?
    end

    test "refuses an age the form does not offer", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        put(conn, ~p"/settings/auto_post_deletion", %{
          "user" => rule(%{"auto_post_deletion_after_days" => "2"})
        })

      assert html_response(conn, 422)
      refute Repo.reload!(user).auto_post_deletion?
    end

    test "reads a cleared engagement floor as off, not as a failed save", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        put(conn, ~p"/settings/auto_post_deletion", %{
          "user" => rule(%{"auto_post_deletion_min_likes" => ""})
        })

      assert redirected_to(conn) == "/settings/auto_post_deletion"
      assert Repo.reload!(user).auto_post_deletion_min_likes == 0
    end
  end

  # vutuv is a German site, and `gettext.extract --merge` fuzzy-fills a new
  # msgid with the translation of whatever it looks similar to — this page
  # arrived with "Your rule" as "Ihre Rolle", "Settings saved." as
  # "Einstellungen" and every one of the nine age labels wrong. Nothing fails a
  # build over that, so the German render is asserted by name, the one-word
  # labels included: they are the likeliest to be fuzzy-matched and the least
  # likely to be noticed.
  describe "the German render" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    # The login already sent a response on this conn, so the header goes on a
    # recycled one (which keeps the session cookie).
    defp de(conn) do
      conn |> recycle() |> put_req_header("accept-language", "de-DE,de;q=0.9")
    end

    test "names the page and its rule in German", %{conn: conn} do
      html = conn |> de() |> get(~p"/settings/auto_post_deletion") |> html_response(200)

      assert html =~ "Automatisches Löschen von Beiträgen"
      assert html =~ "Ihre Regel"
      assert html =~ "Was wir nicht versprechen können"
      assert html =~ "Zwingen können wir ihn nicht."
      assert html =~ "Meine Beiträge automatisch löschen"
      assert html =~ "Immer behalten"
      assert html =~ "Beiträge behalten, die gut liefen"
      assert html =~ "Lesezeichen"
    end

    test "offers the ages as German spans of time, not as a stray noun", %{conn: conn} do
      html = conn |> de() |> get(~p"/settings/auto_post_deletion") |> html_response(200)

      for label <- [
            "1 Tag",
            "3 Tage",
            "1 Woche",
            "2 Wochen",
            "1 Monat",
            "3 Monate",
            "6 Monate",
            "1 Jahr",
            "2 Jahre"
          ] do
        assert html =~ label
      end
    end

    test "asks and reports in German", %{conn: conn, user: user} do
      aged_post!(user, 90)

      html =
        conn
        |> de()
        |> put(~p"/settings/auto_post_deletion", %{"user" => rule()})
        |> html_response(200)

      assert html =~ "1 Beitrag jetzt löschen?"
      assert html =~ "Das lässt sich nicht rückgängig machen."
      assert html =~ "Löschen und speichern"

      conn =
        conn
        |> de()
        |> put(~p"/settings/auto_post_deletion", %{"user" => rule(%{"confirmed" => "true"})})

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "1 Beitrag wurde gelöscht."
    end
  end
end
