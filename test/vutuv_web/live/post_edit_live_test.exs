defmodule VutuvWeb.PostEditLiveTest do
  @moduledoc """
  The edit page: author-only, prefilled composer, saving redirects to the
  permalink with the audience preserved (there is no audience picker), and the
  permalink coordinates never change.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Posts
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Repo

  describe "GET /posts/:id/edit" do
    test "prefills the composer for the author", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, post} =
        Posts.create_post(user, %{
          body: "draft words",
          tags: "elixir",
          denials: [%{"wildcard" => "non_followers"}]
        })

      {:ok, live, html} = live(conn, ~p"/posts/#{post.id}/edit")

      assert html =~ "draft words"
      assert html =~ "elixir"

      # There is no audience picker anymore; the post keeps its followers-only
      # audience on save (see "editing a restricted post keeps its audience").
      refute has_element?(live, "#composer-preset")

      # The corner ✕ that collapses the feed composer is feed-only; the edit
      # page navigates away, so it renders no close-composer control.
      refute has_element?(live, ~s(button[phx-click="close-composer"]))
    end

    test "saving updates the post and navigates to the permalink", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "before"})

      {:ok, live, _html} = live(conn, ~p"/posts/#{post.id}/edit")

      live
      |> form("#composer-form", %{"post" => %{"body" => "after"}})
      |> render_submit()

      assert_redirect(live, Posts.path(post))

      updated = Posts.get_post(post.id)
      assert updated.body == "after"
      # A public post stays public — there is no picker to change its audience.
      assert updated.denials == []
      assert updated.published_on == post.published_on
    end

    test "editing a restricted post keeps its audience", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, post} =
        Posts.create_post(user, %{
          body: "followers only",
          denials: [%{"wildcard" => "non_followers"}]
        })

      {:ok, live, _html} = live(conn, ~p"/posts/#{post.id}/edit")

      # Typing (phx-change) and then saving without an audience field must not
      # widen a restricted post to public now that the picker is gone.
      live
      |> form("#composer-form", %{"post" => %{"body" => "still followers only"}})
      |> render_change()

      live
      |> form("#composer-form", %{"post" => %{"body" => "still followers only"}})
      |> render_submit()

      assert_redirect(live, Posts.path(post))

      updated = Posts.get_post(post.id)
      assert updated.body == "still followers only"
      assert [%{wildcard: "non_followers"}] = updated.denials
    end

    test "editing a custom post collects wildcards and people from the sheet", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      target =
        insert(:user, email_confirmed?: true, first_name: "Maxima", last_name: "Musterfrau")

      # A pre-existing custom post is the only way to reach the Hide-from sheet
      # now (new posts publish public, with no audience picker).
      {:ok, post} =
        Posts.create_post(user, %{
          body: "not for everyone",
          denials: [%{"wildcard" => "logged_out"}]
        })

      {:ok, live, html} = live(conn, ~p"/posts/#{post.id}/edit")
      assert html =~ "Hide this post from"

      # Typeahead: search, then deny the person.
      html =
        live
        |> form("#composer-form", %{"post" => %{"user_search" => "Maxima"}})
        |> render_change()

      assert html =~ "Maxima Musterfrau"

      live
      |> element("#composer-user-results button", "Maxima")
      |> render_click()

      # Save with the wildcard kept on.
      live
      |> form("#composer-form", %{
        "post" => %{
          "body" => "not for everyone",
          "deny_wildcards" => %{"logged_out" => "true"}
        }
      })
      |> render_submit()

      assert_redirect(live, Posts.path(post))

      updated = Posts.get_post(post.id)
      assert length(updated.denials) == 2
      assert Enum.any?(updated.denials, &(&1.wildcard == "logged_out"))
      assert Enum.any?(updated.denials, &(&1.denied_user_id == target.id))
    end

    test "deny-user with a tampered non-UUID id is a no-op, not a crash", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      _target =
        insert(:user, email_confirmed?: true, first_name: "Maxima", last_name: "Musterfrau")

      {:ok, post} =
        Posts.create_post(user, %{
          body: "not for everyone",
          denials: [%{"wildcard" => "logged_out"}]
        })

      {:ok, live, _html} = live(conn, ~p"/posts/#{post.id}/edit")

      # The custom post already shows the sheet; search to surface a deny-user
      # control, then tamper the id the client sends. A non-UUID must not reach
      # Repo.get as a raw cast (which would raise CastError and kill the composer).
      live
      |> form("#composer-form", %{"post" => %{"user_search" => "Maxima"}})
      |> render_change()

      live
      |> element("#composer-user-results button", "Maxima")
      |> render_click(%{"id" => "not-a-uuid"})

      assert Process.alive?(live.pid)
      assert render(live) =~ "Hide this post from"
      # The tampered id denied nobody (no "remove" chip rendered).
      refute has_element?(live, "button[phx-click=undeny-user]")
    end

    test "locks the audience while reposts exist", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "carried by others"})
      :ok = Posts.repost_post(insert(:user, email_confirmed?: true), post)

      {:ok, live, html} = live(conn, ~p"/posts/#{post.id}/edit")

      # No audience select; the locked chip and the explanation instead.
      refute has_element?(live, "#composer-preset")
      assert has_element?(live, "#composer-audience-locked")
      assert html =~ "reposted"

      # Body edits still save (and the post stays public).
      live
      |> form("#composer-form", %{"post" => %{"body" => "still editable"}})
      |> render_submit()

      assert_redirect(live, Posts.path(post))
      assert Posts.get_post(post.id).body == "still editable"
      assert Posts.get_post(post.id).denials == []
    end

    test "locks the audience while replies exist", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "carried by a thread"})

      {:ok, _} =
        Posts.create_reply(insert(:user, email_confirmed?: true), post, %{body: "the answer"})

      {:ok, live, html} = live(conn, ~p"/posts/#{post.id}/edit")

      refute has_element?(live, "#composer-preset")
      assert has_element?(live, "#composer-audience-locked")
      assert html =~ "replies"
    end

    test "sends non-authors away without confirming existence", %{conn: conn} do
      author = insert(:user, email_confirmed?: true)
      {:ok, post} = Posts.create_post(author, %{body: "not yours"})

      {conn, _other} = create_and_login_user(conn)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/posts/#{post.id}/edit")
      # A valid-but-absent id and a garbage id both redirect (no 500, no probe).
      assert {:error, {:redirect, %{to: "/"}}} =
               live(conn, ~p"/posts/#{Vutuv.UUIDv7.generate()}/edit")

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/posts/999999/edit")
    end
  end

  describe "removing a bad auto link screenshot" do
    test "the author can remove the captured screenshot from the edit page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = post_with_ready_screenshot(user)

      {:ok, live, _html} = live(conn, ~p"/posts/#{post.id}/edit")
      assert has_element?(live, "#post-screenshot-editor")

      live
      |> element("#remove-screenshot")
      |> render_click()

      # The screenshot section is gone the moment it is dismissed, no reload.
      refute has_element?(live, "#post-screenshot-editor")

      job = Repo.get_by!(PostScreenshot, post_id: post.id)
      assert job.status == "dismissed"
      assert job.screenshot == nil
    end

    test "no remove control when the post carries no screenshot", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "just words, no link"})

      {:ok, live, _html} = live(conn, ~p"/posts/#{post.id}/edit")
      refute has_element?(live, "#post-screenshot-editor")
    end

    test "a still-capturing screenshot shows no remove control yet", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "Check https://example.com/page"})

      Repo.insert!(%PostScreenshot{
        post_id: post.id,
        url: "https://example.com/page",
        status: "pending"
      })

      {:ok, live, _html} = live(conn, ~p"/posts/#{post.id}/edit")
      refute has_element?(live, "#post-screenshot-editor")
    end
  end

  # A single-URL, image-less post whose auto-screenshot has been captured,
  # stored and released — the state in which the card renders it.
  defp post_with_ready_screenshot(author) do
    {:ok, post} = Posts.create_post(author, %{body: "Check https://example.com/page"})

    Repo.insert!(%PostScreenshot{
      post_id: post.id,
      url: "https://example.com/page",
      status: "ready",
      screenshot: "0123456789ab.avif",
      moderation: "approved"
    })

    post
  end
end
