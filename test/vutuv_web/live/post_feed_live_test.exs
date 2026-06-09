defmodule VutuvWeb.PostFeedLiveTest do
  @moduledoc """
  The /feed LiveView: composer round trips (body, tags, audience presets and
  the custom sheet), live prepend of own posts, the "Show N new posts" pill
  for followed authors (visibility-checked), and cursor pagination.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Posts

  defp other_user(attrs \\ []), do: insert(:user, Keyword.merge([activated?: true], attrs))

  describe "mount" do
    test "redirects logged-out visitors to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/feed")
    end

    test "shows own and followees' posts, newest first", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      {:ok, _} = Posts.create_post(user, %{body: "my words"})
      {:ok, _} = Posts.create_post(friend, %{body: "friend words"})
      {:ok, _} = Posts.create_post(other_user(), %{body: "stranger words"})

      {:ok, _live, html} = live(conn, ~p"/feed")

      assert html =~ "my words"
      assert html =~ "friend words"
      refute html =~ "stranger words"
    end
  end

  describe "composer" do
    test "creates a public post that appears in the feed", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      live
      |> form("#composer-form", %{"post" => %{"body" => "Hello **feed**", "tags" => "elixir"}})
      |> render_submit()

      html = render(live)
      assert html =~ "<strong>feed</strong>"
      assert html =~ "elixir"
      # The composer reset for the next post.
      refute live |> element("#composer-body") |> render() =~ "Hello"
    end

    test "the audience preset becomes the matching denial", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      live
      |> form("#composer-form", %{
        "post" => %{"body" => "inner circle", "preset" => "followers"}
      })
      |> render_submit()

      [%{post: post}] = Posts.profile_posts(user, user)
      assert [%{wildcard: "non_followers"}] = post.denials

      # The preset sticks for the next post (last-used default).
      assert live |> element("#composer-preset") |> render() =~
               ~s(option value="followers" selected)
    end

    test "the custom sheet collects groups, wildcards and people", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      group = insert(:group, user: user, name: "Ex colleagues")
      target = other_user(first_name: "Maxima", last_name: "Musterfrau")

      {:ok, live, _html} = live(conn, ~p"/feed")

      # Switching to custom opens the sheet.
      html =
        live
        |> form("#composer-form", %{"post" => %{"preset" => "custom"}})
        |> render_change()

      assert html =~ "Hide this post from"
      assert html =~ "Ex colleagues"

      # Typeahead: search, then deny the person.
      html =
        live
        |> form("#composer-form", %{
          "post" => %{"preset" => "custom", "user_search" => "Maxima"}
        })
        |> render_change()

      assert html =~ "Maxima Musterfrau"

      live
      |> element("#composer-user-results button", "Maxima")
      |> render_click()

      # Submit with the group checked and a wildcard on.
      live
      |> form("#composer-form", %{
        "post" => %{
          "body" => "not for everyone",
          "preset" => "custom",
          "deny_groups" => %{"#{group.id}" => "true"},
          "deny_wildcards" => %{"logged_out" => "true"}
        }
      })
      |> render_submit()

      [%{post: post}] = Posts.profile_posts(user, user)
      assert length(post.denials) == 3
      assert Enum.any?(post.denials, &(&1.group_id == group.id))
      assert Enum.any?(post.denials, &(&1.wildcard == "logged_out"))
      assert Enum.any?(post.denials, &(&1.denied_user_id == target.id))
    end

    test "publishes a photo-only post (upload, no text)", %{conn: conn} do
      # Real files land on disk: isolate the uploads root per test.
      tmp =
        Path.join(System.tmp_dir!(), "vutuv_feed_upload_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      prev = Application.get_env(:vutuv, :uploads_dir_prefix)
      Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

      on_exit(fn ->
        File.rm_rf(tmp)

        if prev,
          do: Application.put_env(:vutuv, :uploads_dir_prefix, prev),
          else: Application.delete_env(:vutuv, :uploads_dir_prefix)
      end)

      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      {:ok, image} = Image.new(64, 64, color: [10, 100, 200])
      {:ok, png} = Image.write(image, :memory, suffix: ".png")

      live
      |> file_input("#composer-form", :images, [
        %{name: "photo.png", content: png, type: "image/png"}
      ])
      |> render_upload("photo.png")

      live
      |> form("#composer-form", %{"post" => %{"body" => ""}})
      |> render_submit()

      refute has_element?(live, "#composer-error")

      assert [%{post: post}] = Posts.profile_posts(user, user)
      assert post.body == ""
      assert [attached] = post.images

      # The feed shows a single image at column width (feed version, aspect
      # preserved) — not a square micro-thumbnail.
      assert render(live) =~ "/post_images/#{attached.token}/feed.avif"
    end

    test "a refused file is named in a persistent error and the composer recovers", %{
      conn: conn
    } do
      # Shrink the size limit so a tiny test file is "too large". Must be set
      # before mount — allow_upload reads it when the composer initializes.
      prev = Application.get_env(:vutuv, :post_images)
      Application.put_env(:vutuv, :post_images, max_filesize: 1_000, max_per_post: 10)
      on_exit(fn -> Application.put_env(:vutuv, :post_images, prev) end)

      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      upload =
        file_input(live, "#composer-form", :images, [
          %{name: "huge-photo.png", content: String.duplicate("x", 2_000), type: "image/png"}
        ])

      # The preflight refuses the file (client-side rule, enforced server-side
      # in tests). The next form change sweeps it into a visible error.
      assert {:error, _} = render_upload(upload, "huge-photo.png")

      live
      |> form("#composer-form", %{"post" => %{"body" => ""}})
      |> render_change()

      assert has_element?(live, "#composer-error")
      assert render(live) =~ "huge-photo.png"

      # The rejected entry was cancelled: posting still works.
      live
      |> form("#composer-form", %{"post" => %{"body" => "text without the photo"}})
      |> render_submit()

      assert [%{post: post}] = Posts.profile_posts(user, user)
      assert post.images == []
    end

    test "rejects an empty post with an inline error", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      live
      |> form("#composer-form", %{"post" => %{"body" => "   "}})
      |> render_submit()

      assert has_element?(live, "#composer-error")
    end
  end

  describe "owner menu" do
    test "own posts carry the ⋯ menu with Edit and Delete, others' posts do not", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      {:ok, mine} = Posts.create_post(user, %{body: "my words"})
      {:ok, theirs} = Posts.create_post(friend, %{body: "friend words"})

      {:ok, live, _html} = live(conn, ~p"/feed")

      assert has_element?(live, "#post-menu-post-#{mine.id} a[href='/posts/#{mine.id}/edit']")
      assert has_element?(live, "#post-menu-post-#{mine.id} a[data-method='delete']")
      refute has_element?(live, "#post-menu-post-#{theirs.id}")
    end
  end

  describe "live updates" do
    test "a followed author's new post shows the pill, not the post", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      {:ok, live, _html} = live(conn, ~p"/feed")

      {:ok, _post} = Posts.create_post(friend, %{body: "breaking news"})

      html = render(live)
      assert html =~ "Show 1 new post"
      refute html =~ "breaking news"

      live |> element("#show-new-posts") |> render_click()
      assert render(live) =~ "breaking news"
    end

    test "a denied post never reaches the pill", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      {:ok, live, _html} = live(conn, ~p"/feed")

      # friend hides the post from people they don't follow (they don't
      # follow our viewer back).
      {:ok, _} =
        Posts.create_post(friend, %{
          body: "secret",
          denials: [%{"wildcard" => "non_followees"}]
        })

      html = render(live)
      refute html =~ "Show 1 new post"
      refute html =~ "secret"
    end
  end

  describe "pagination" do
    test "loads older posts on demand", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      for n <- 1..21, do: {:ok, _} = Posts.create_post(user, %{body: "post number #{n}"})

      {:ok, live, html} = live(conn, ~p"/feed")

      assert html =~ "post number 21"
      refute html =~ "post number 1<"
      assert has_element?(live, "#load-more")

      live |> element("#load-more") |> render_click()
      assert render(live) =~ "post number 1"
      refute has_element?(live, "#load-more")
    end
  end
end
