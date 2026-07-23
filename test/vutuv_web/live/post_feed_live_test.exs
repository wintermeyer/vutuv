defmodule VutuvWeb.PostFeedLiveTest do
  @moduledoc """
  The /feed LiveView: composer round trips (body, tags, public-by-default posts
  and the deny "Hide from…" sheet), live prepend of own posts, the "Show N new
  posts" pill for followed authors (visibility-checked), and cursor pagination.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage

  defp other_user(attrs \\ []), do: insert(:user, Keyword.merge([email_confirmed?: true], attrs))

  # Where `text` first shows up in the rendered feed — how the thread tests
  # assert reading order without parsing the whole card tree.
  defp position(html, text) do
    case :binary.match(html, text) do
      {at, _} -> at
      :nomatch -> flunk("#{inspect(text)} is not on the page")
    end
  end

  describe "engagement query batching" do
    test "feed engagement queries do not grow with post count", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      for n <- 1..3, do: {:ok, _} = Posts.create_post(friend, %{body: "post #{n}"})
      {_, few} = Vutuv.QueryCounter.count_queries(fn -> get(conn, ~p"/feed") end)

      for n <- 4..13, do: {:ok, _} = Posts.create_post(friend, %{body: "post #{n}"})
      {_, many} = Vutuv.QueryCounter.count_queries(fn -> recycle(conn) |> get(~p"/feed") end)

      # 10 more posts must not add ~10 per-card engagement queries: the feed
      # pre-loads engagement for the whole page in one batch and hands it to the
      # action bars (it used to run one post_engagement query per card on mount).
      assert many <= few + 2,
             "feed query count grew from #{few} to #{many}; engagement is not batched"
    end
  end

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

      {:ok, live, html} = live(conn, ~p"/feed")

      assert html =~ "my words"
      assert html =~ "friend words"
      # The stranger's post stays out of the timeline (it may still surface in
      # the rail's "Suggested posts" discovery card — that is the card's job).
      refute has_element?(live, "#feed-posts", "stranger words")
    end

    test "opens with the composer card, no visible headline or saved-hub links", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, view, _html} = live(conn, ~p"/feed")

      # The page opens with a card-weight composer trigger (avatar plus an
      # input-shaped pill), not the dashed onboarding tile; the h1 stays for
      # screen readers only. The old Likes/Bookmarks header links were
      # redundant — both live in the avatar menu and as tabs on the saved hub.
      assert has_element?(view, "#open-composer[data-composer-trigger]", "Write a post")
      refute has_element?(view, "#open-composer[data-empty-add]")
      assert has_element?(view, "#feed h1.sr-only", "Feed")
      refute has_element?(view, ~s(#feed a[href="/likes"]))
      refute has_element?(view, ~s(#feed a[href="/bookmarks"]))
    end
  end

  describe "threaded replies" do
    test "a reply shows the post it answers inline, not a bare handle banner", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      {:ok, parent} = Posts.create_post(friend, %{body: "the original question"})
      {:ok, reply} = Posts.create_reply(user, parent, %{body: "my answer to it"})

      {:ok, live, html} = live(conn, ~p"/feed")

      # The reply carries the post it answers as an inline context preview
      # (the same treatment as the profile), linking to the parent post — not
      # the flat "Replying to @handle" text banner.
      assert html =~ "the original question"
      assert has_element?(live, ~s(#feed-posts a[href="#{Posts.path(parent)}"]))
      refute has_element?(live, "[data-reply-banner]")

      # And the parent is shown *only* nested under the reply, never also as its
      # own standalone row — the followed author's post used to appear twice.
      assert has_element?(live, "#feed-post-#{reply.id}")
      refute has_element?(live, "#feed-post-#{parent.id}")

      # Both the reply *and* the post it answers are full cards that keep their
      # own action bar (like / repost / bookmark), so every element of the
      # thread can be acted on — the parent is no longer a faint read-only
      # excerpt. The parent's bar is keyed under the leaf entry so the two bars
      # never collide.
      assert has_element?(live, "#post-actions-post-#{reply.id}-like")
      assert has_element?(live, "#post-actions-post-#{reply.id}-parent-#{parent.id}-like")

      # The vertical connector "drop" that threads the parent's avatar down into
      # the reply must size itself with an explicit height (calc(100% - top)),
      # never a `top`/`bottom` auto-height: an empty absolutely-positioned box
      # sized only by top+bottom collapses to zero on iOS/mobile Safari, which
      # made the whole thread line disappear on phones (issue: "line doesn't
      # show up in the mobile version"). Lock the hardened form in.
      feed_html = live |> element("#feed-posts") |> render()
      assert feed_html =~ "h-[calc(100%-2.25rem)]"
    end

    test "replying live removes the parent's standalone row, keeping the thread", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      {:ok, parent} = Posts.create_post(friend, %{body: "the original question"})

      {:ok, live, _html} = live(conn, ~p"/feed")
      # The parent is on the open feed as its own row.
      assert has_element?(live, "#feed-post-#{parent.id}")

      # The viewer replies (broadcasts to their own session): the reply lands
      # at the top nesting the parent, and the standalone parent row is pruned.
      {:ok, reply} = Posts.create_reply(user, parent, %{body: "my live answer"})
      _ = :sys.get_state(live.pid)

      assert has_element?(live, "#feed-post-#{reply.id}")
      refute has_element?(live, "#feed-post-#{parent.id}")

      # The nested parent card carries its own action bar for the live-arrived
      # reply too (one-level nesting; its bar self-loads engagement).
      assert has_element?(live, "#post-actions-post-#{reply.id}-parent-#{parent.id}-like")
    end

    test "a multi-post thread across users renders once, not fragmented pairs", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      # A three-post conversation spanning two users: user roots it, friend
      # answers, user answers again. All three are on the viewer's feed (own +
      # followed), so the whole chain is present.
      {:ok, root} = Posts.create_post(user, %{body: "the root question"})
      {:ok, mid} = Posts.create_reply(friend, root, %{body: "the middle answer"})
      {:ok, leaf} = Posts.create_reply(user, mid, %{body: "the final word"})

      {:ok, live, html} = live(conn, ~p"/feed")

      # The whole thread renders once as a single conversation — each post shown
      # exactly once. The middle post used to appear twice (its own row *and*
      # nested under the leaf); it must not any more.
      assert html =~ "the root question"
      assert html =~ "the middle answer"
      assert html =~ "the final word"
      assert length(String.split(html, "the middle answer")) - 1 == 1

      # Only the leaf keeps its standalone stream row; the root and middle are
      # nested inside that one thread, so their own rows are dropped.
      assert has_element?(live, "#feed-post-#{leaf.id}")
      refute has_element?(live, "#feed-post-#{mid.id}")
      refute has_element?(live, "#feed-post-#{root.id}")

      # Every post in the thread keeps its own action bar.
      assert has_element?(live, "#post-actions-post-#{leaf.id}-like")
      assert has_element?(live, "#post-actions-post-#{leaf.id}-parent-#{mid.id}-like")
      assert has_element?(live, "#post-actions-post-#{leaf.id}-parent-#{root.id}-like")
    end

    test "a branching thread nests each reply under the post it answers", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      # One root answered twice; the newest reply belongs to the *first* branch.
      {:ok, root} = Posts.create_post(user, %{body: "the branch root"})
      {:ok, alpha} = Posts.create_reply(friend, root, %{body: "alpha branch"})
      {:ok, beta} = Posts.create_reply(friend, root, %{body: "beta branch"})
      {:ok, _} = Posts.create_reply(user, beta, %{body: "answer under beta"})
      {:ok, _} = Posts.create_reply(user, alpha, %{body: "the late answer"})

      {:ok, live, _html} = live(conn, ~p"/feed")
      feed_html = live |> element("#feed-posts") |> render()

      # The collapsed thread renders as the tree it is, not as a timeline: the
      # newest reply hangs under the alpha branch it answers, ahead of the whole
      # beta branch (issue #1027).
      assert position(feed_html, "alpha branch") < position(feed_html, "the late answer")
      assert position(feed_html, "the late answer") < position(feed_html, "beta branch")
      assert position(feed_html, "beta branch") < position(feed_html, "answer under beta")

      # A card whose parent is nested right above it says so by its position;
      # the redundant "Replying to @handle" banner stays off.
      refute feed_html =~ "Replying to"
    end

    test "a deep thread caps its indentation so it can't scroll a phone sideways", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      # A seven-post back-and-forth (root + six replies, alternating authors), all
      # on the viewer's feed so the whole chain collapses into one thread.
      {:ok, root} = Posts.create_post(user, %{body: "chain post 0"})

      _leaf =
        Enum.reduce(1..6, root, fn n, parent ->
          author = if rem(n, 2) == 0, do: user, else: friend
          {:ok, reply} = Posts.create_reply(author, parent, %{body: "chain post #{n}"})
          reply
        end)

      {:ok, live, html} = live(conn, ~p"/feed")

      # Every post in the thread still renders (nothing is dropped to save width).
      for n <- 0..6, do: assert(html =~ "chain post #{n}")

      # But the indentation is capped: a 7-deep thread indents at most twice
      # (@thread_indent_cap), not six times, so it can't march off the right edge
      # of a phone. `border-l-2` is the indented connector elbow (the only feed
      # use of it); capped-depth connectors are a plain vertical drop instead.
      feed_html = live |> element("#feed-posts") |> render()
      indents = length(String.split(feed_html, "border-l-2")) - 1
      assert indents <= 2, "expected the indent to cap at 2 levels, got #{indents}"
    end

    test "the timeline renders as one card, not one card per post", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      for n <- 1..3, do: {:ok, _} = Posts.create_post(friend, %{body: "post #{n}"})

      {:ok, live, _html} = live(conn, ~p"/feed")

      # The posts stream is the card surface itself (divide-y flat rows), the
      # same container the profile Posts section uses — so the feed and the
      # profile read as one UX, not "separate cards" vs "one card".
      assert has_element?(live, ~s(#feed-posts[data-post-list]))
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

    test "a new post from the composer is public", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      # No audience picker: a plain compose-and-post publishes public.
      live
      |> form("#composer-form", %{"post" => %{"body" => "inner circle"}})
      |> render_submit()

      [%{post: post}] = Posts.profile_posts(user, user)
      assert post.denials == []
    end

    # The custom "Hide from…" sheet is only reachable when editing a pre-existing
    # custom post now (new posts publish public), so its coverage lives in
    # post_edit_live_test.exs.

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

    test "an uploaded image gets alt + remove + inline-insert controls", %{
      conn: conn
    } do
      tmp =
        Path.join(System.tmp_dir!(), "vutuv_feed_inline_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      prev = Application.get_env(:vutuv, :uploads_dir_prefix)
      Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

      on_exit(fn ->
        File.rm_rf(tmp)

        if prev,
          do: Application.put_env(:vutuv, :uploads_dir_prefix, prev),
          else: Application.delete_env(:vutuv, :uploads_dir_prefix)
      end)

      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      {:ok, image} = Image.new(64, 64, color: [10, 100, 200])
      {:ok, png} = Image.write(image, :memory, suffix: ".png")

      live
      |> file_input("#composer-form", :images, [
        %{name: "photo.png", content: png, type: "image/png"}
      ])
      |> render_upload("photo.png")

      # The normal upload feature stays: the picker and per-image alt + remove
      # controls are still there.
      assert render(live) =~ "Add images"
      assert has_element?(live, ~s([phx-click="remove-image"]))

      # The completed upload is announced to the editor hook (which decides
      # whether this file was dropped/pasted into the prose and should be
      # inserted at the cursor).
      assert_push_event(live, "mde-image-uploaded", %{
        editor: "composer-body",
        name: "photo.png",
        url: "/post_images/" <> _
      })

      # Each thumbnail row offers "Insert into text": clicking it tells the
      # editor hook to place the image at the cursor.
      assert has_element?(live, ~s([phx-click="insert-inline"]))
      [image] = Vutuv.Repo.all(PostImage)

      live
      |> element(~s(button[phx-click="insert-inline"][phx-value-id="#{image.id}"]))
      |> render_click()

      expected_url = PostImage.url(image, "feed")

      assert_push_event(live, "mde-insert-image", %{
        editor: "composer-body",
        url: ^expected_url
      })
    end

    test "an inline-referenced image renders inside the preview body, not below it", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      image = insert(:post_image, user: user, post: nil, token: "feedinline")

      {:ok, _} =
        Posts.create_post(user, %{
          body: "Before the picture ![](/post_images/feedinline/feed.avif#left) and after it.",
          image_ids: [image.id]
        })

      {:ok, live, _html} = live(conn, ~p"/feed")
      html = render(live)

      # The picture sits inline in the body (alignment modifier included)…
      assert html =~ "post-inline-image post-inline-image--left"
      # …exactly once: the preview's image tile row must not repeat it.
      assert length(String.split(html, "/post_images/feedinline/feed.avif")) == 2
      # The body uses the height-based media clamp (line-clamp cannot hold
      # floats/images), so the image is visible instead of hidden by the cut.
      assert html =~ "post-clamp--media"
    end

    test "preview tags follow the end of the text, not the floated image", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      ref = insert(:post_image, user: user, post: nil, token: "tagfeedref")
      gal = insert(:post_image, user: user, post: nil, token: "tagfeedgal")

      {:ok, _} =
        Posts.create_post(user, %{
          body: "Text beside ![](/post_images/tagfeedref/feed.avif#right) a floated picture.",
          tags: "elixir",
          image_ids: [ref.id, gal.id]
        })

      {:ok, _live, html} = live(conn, ~p"/feed")

      # The tag chips sit inside the clamp block right after the text (beside
      # the float), so they come before the fade/read-more markup that follows
      # the block and before the unreferenced-attachment tile row — a tall
      # float used to push them below the whole picture…
      {tag_pos, _} = :binary.match(html, ~s(href="/tags/elixir"))
      {fade_pos, _} = :binary.match(html, "post-preview__fade")
      {gallery_pos, _} = :binary.match(html, "/post_images/tagfeedgal/feed.avif")
      assert tag_pos < fade_pos
      assert tag_pos < gallery_pos

      # …and a second, CSS-toggled copy below the block stands in while the
      # body is clamped (the inline row would be cut away with the text).
      assert html =~ "post-preview__tags-below"
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

    test "a mention of a non-existent handle is rejected with a readable error", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      html =
        live
        |> form("#composer-form", %{"post" => %{"body" => "Ein Test. @asfasfwa87823"}})
        |> render_submit()

      assert has_element?(live, "#composer-error")
      # The offending handle is named so the author knows what to fix, and the
      # raw interpolation placeholder and leaking field atom are both gone.
      assert html =~ "@asfasfwa87823"
      refute html =~ "%{handles}"
      refute html =~ "body mentions"
    end

    test "the mention error is shown in German for a German member", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      user |> Ecto.Changeset.change(%{locale: "de"}) |> Vutuv.Repo.update!()

      {:ok, live, _html} = live(conn, ~p"/feed")

      html =
        live
        |> form("#composer-form", %{"post" => %{"body" => "Ein Test. @asfasfwa87823"}})
        |> render_submit()

      assert html =~ "@asfasfwa87823"
      assert html =~ "gibt es nicht"
      refute html =~ "%{handles}"
    end
  end

  describe "composer reveal" do
    test "the composer is collapsed behind a button until clicked", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      # Collapsed: the trigger shows and the composer panel is hidden. The "n"
      # keyboard shortcut (assets/js/keyboard_shortcuts.js) relies on exactly
      # this shape on a collapsed feed: the textarea (#composer-body) is already
      # in the DOM (just display:none inside the hidden panel) and the reveal
      # trigger is #open-composer, which the shortcut clicks before focusing.
      # Renaming either id silently breaks the shortcut, so pin both here.
      assert has_element?(live, "#open-composer")
      assert has_element?(live, "#composer-panel.hidden")
      assert has_element?(live, "#composer-panel.hidden #composer-body")

      live |> element("#open-composer") |> render_click()

      # Revealed: the panel is no longer hidden and the trigger is gone.
      refute has_element?(live, "#composer-panel.hidden")
      refute has_element?(live, "#open-composer")
    end

    test "the composer drops the audience picker and its summary line", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      live |> element("#open-composer") |> render_click()

      # The compose row was simplified: no per-post audience picker (posts
      # publish public) and no one-line audience summary. The full-width tags
      # field and the Post submit stay.
      refute has_element?(live, "#composer-preset")
      refute has_element?(live, "#composer-audience-summary")
      assert has_element?(live, ~s(#composer-form input[name="post[tags]"]))
      assert has_element?(live, ~s(#composer-form button[type="submit"]))
    end

    test "the corner ✕ collapses the composer again", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      live |> element("#open-composer") |> render_click()
      refute has_element?(live, "#open-composer")

      # The composer's corner ✕ (feed compose only) bubbles up to the feed and
      # collapses the panel again.
      assert has_element?(live, ~s(#composer-form button[phx-click="close-composer"]))

      live |> element(~s(#composer-form button[phx-click="close-composer"])) |> render_click()

      assert has_element?(live, "#open-composer")
      assert has_element?(live, "#composer-panel.hidden")
    end

    test "posting collapses the composer back to the button", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      live |> element("#open-composer") |> render_click()
      refute has_element?(live, "#open-composer")

      live
      |> form("#composer-form", %{"post" => %{"body" => "first words"}})
      |> render_submit()

      # The viewer's own post arrived below, so the composer collapsed again.
      assert has_element?(live, "#open-composer")
      assert has_element?(live, "#composer-panel.hidden")
    end
  end

  describe "who to follow rail" do
    test "suggests a popular member with a Follow button", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      popular = other_user(first_name: "Pop", last_name: "Ular")
      # most_followed_users ranks by follower count, so give them one follower.
      insert(:follow, follower: other_user(), followee: popular)

      {:ok, live, _html} = live(conn, ~p"/feed")

      assert has_element?(live, ~s(#who-to-follow a[href="/#{popular.username}"]))
      assert has_element?(live, ~s(#who-to-follow button[phx-value-followee="#{popular.id}"]))
    end

    test "does not suggest members the viewer already follows", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      already = other_user(first_name: "Al", last_name: "Ready")
      fresh = other_user(first_name: "Fresh", last_name: "Face")
      # Both are popular (need a visible follower to rank), but the viewer
      # already follows `already` — that follow also counts as their follower.
      insert(:follow, follower: user, followee: already)
      insert(:follow, follower: other_user(), followee: fresh)

      {:ok, live, _html} = live(conn, ~p"/feed")

      assert Vutuv.Social.user_follows_user?(user.id, already.id)
      assert has_element?(live, ~s(#who-to-follow a[href="/#{fresh.username}"]))
      refute has_element?(live, ~s(#who-to-follow a[href="/#{already.username}"]))
    end

    test "following a suggestion drops it from the rail", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      popular = other_user(first_name: "Pop", last_name: "Ular")
      insert(:follow, follower: other_user(), followee: popular)

      {:ok, live, _html} = live(conn, ~p"/feed")

      live
      |> element(~s(#who-to-follow button[phx-value-followee="#{popular.id}"]))
      |> render_click()

      # Following makes them a followee, so the suggestion is no longer relevant
      # and the row drops out (no point listing someone you already follow).
      assert Vutuv.Social.user_follows_user?(user.id, popular.id)
      refute has_element?(live, ~s(#who-to-follow a[href="/#{popular.username}"]))
      refute has_element?(live, ~s(#who-to-follow button[phx-value-followee="#{popular.id}"]))
    end

    test "randomizes which eligible members it suggests across visits", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      # A pool larger than the 6 shown, so the rail must pick a subset. Each is
      # popular enough to rank (one visible follower); none is followed by the
      # viewer, so all are eligible suggestions.
      pool =
        for n <- 1..10 do
          member = other_user(first_name: "Member", last_name: "No#{n}")
          insert(:follow, follower: other_user(), followee: member)
          member
        end

      # The rail shuffles its candidates, so revisiting the feed surfaces a
      # different slate. Over several visits the union of who was shown must
      # exceed the 6 shown at once — a fixed top-6 ordering never would.
      shown =
        Enum.reduce(1..12, MapSet.new(), fn _i, acc ->
          {:ok, live, _html} = live(recycle(conn), ~p"/feed")

          pool
          |> Enum.filter(&has_element?(live, ~s(#who-to-follow a[href="/#{&1.username}"])))
          |> Enum.reduce(acc, &MapSet.put(&2, &1.id))
        end)

      assert MapSet.size(shown) > 6
    end

    test "a periodic refresh reshuffles the suggestions in place", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      popular = other_user(first_name: "Pop", last_name: "Ular")
      insert(:follow, follower: other_user(), followee: popular)

      {:ok, live, _html} = live(conn, ~p"/feed")
      assert has_element?(live, ~s(#who-to-follow a[href="/#{popular.username}"]))

      # The mount schedules a refresh timer; firing it by hand must recompute the
      # rail (and not crash), keeping the eligible suggestion visible.
      send(live.pid, :refresh_suggestions)
      _ = render(live)

      assert has_element?(live, ~s(#who-to-follow a[href="/#{popular.username}"]))
    end
  end

  describe "suggested posts rail" do
    test "shows a same-language stranger's post with author link, permalink and reload", %{
      conn: conn
    } do
      {conn, _user} = create_and_login_user(conn)
      author = other_user(first_name: "New", last_name: "Voice")
      {:ok, post} = Posts.create_post(author, %{body: "something worth discovering"})

      {:ok, live, _html} = live(conn, ~p"/feed")

      assert has_element?(live, ~s(#discover-posts a[href="/#{author.username}"]))

      assert has_element?(
               live,
               ~s(#discover-posts a[href="/#{author.username}/posts/#{post.id}"])
             )

      assert has_element?(live, ~s(#discover-reshuffle[phx-click="reshuffle-discover"]))
    end

    test "skips followed authors and other-language members", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      followed = other_user(first_name: "Al", last_name: "Ready")
      german = other_user(first_name: "Deutsch", last_name: "Sprecher", locale: "de")
      fresh = other_user(first_name: "Fresh", last_name: "Face")
      insert(:follow, follower: user, followee: followed)

      {:ok, followed_post} = Posts.create_post(followed, %{body: "followed words"})
      {:ok, german_post} = Posts.create_post(german, %{body: "deutsche Worte"})
      {:ok, fresh_post} = Posts.create_post(fresh, %{body: "fresh words"})

      {:ok, live, _html} = live(conn, ~p"/feed")

      assert has_element?(
               live,
               ~s(#discover-posts a[href="/#{fresh.username}/posts/#{fresh_post.id}"])
             )

      refute has_element?(
               live,
               ~s(#discover-posts a[href="/#{followed.username}/posts/#{followed_post.id}"])
             )

      refute has_element?(
               live,
               ~s(#discover-posts a[href="/#{german.username}/posts/#{german_post.id}"])
             )
    end

    test "hides the card when nothing is eligible", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")

      refute has_element?(live, "#discover-posts")
    end

    test "renders the body as formatted Markdown, clamped at six lines", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      author = other_user(first_name: "Long", last_name: "Winded")

      {:ok, post} =
        Posts.create_post(author, %{
          body: "# **Zwischenüberschrift**\n\nA second paragraph that must stay visible."
        })

      {:ok, live, _html} = live(conn, ~p"/feed")
      html = render(live)

      body = ~s(#discover-posts .markdown--post)

      # The body runs through the same Markdown formatter as a normal post, so the
      # raw Markdown source (the leading `#`, the `**`) never reaches the DOM …
      assert has_element?(live, body)
      refute html =~ "# **Zwischenüberschrift**"
      # … the heading flattens to bold text, later paragraphs stay visible …
      assert has_element?(live, "#{body} strong", "Zwischenüberschrift")
      assert has_element?(live, body, "A second paragraph that must stay visible.")
      # … the visible cut is the six-line CSS clamp, not the old four-line/one-line …
      assert has_element?(live, "#{body}.line-clamp-6")
      refute has_element?(live, "#discover-posts .line-clamp-4")
      refute has_element?(live, "#discover-posts .truncate")

      # … and the permalink to the post is still reachable (the stretched link).
      assert has_element?(
               live,
               ~s(#discover-posts a[href="/#{author.username}/posts/#{post.id}"])
             )
    end

    test "the rail hyphenates and a click on the body opens the post", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      author = other_user(first_name: "Lang", last_name: "Wort")

      {:ok, post} =
        Posts.create_post(author, %{
          body: "Eine Digitalisierungsstrategie für unternehmenseigene Softwareentwicklung."
        })

      {:ok, live, _html} = live(conn, ~p"/feed")

      # Browser hyphenation is switched on for the narrow rail column via the
      # `.markdown--post` seam (auto on desktop too, not just the phone default),
      # so long German compounds wrap at syllables instead of leaving big gaps.
      assert has_element?(
               live,
               ~s(#discover-posts .markdown--post[style*="--post-hyphens-desktop:auto"])
             )

      # The whole row is a stretched link to the post, so a click on the body
      # text (not only the timestamp) opens the corresponding posting.
      assert has_element?(
               live,
               ~s(#discover-posts a.absolute.inset-0[href="/#{author.username}/posts/#{post.id}"])
             )
    end

    test "the reload control draws a fresh random handful without a reload", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      # More eligible authors than the 5 shown, so each draw picks a subset.
      pool =
        for n <- 1..10 do
          author = other_user(first_name: "Voice", last_name: "No#{n}")
          {:ok, post} = Posts.create_post(author, %{body: "discover me #{n}"})
          {author, post}
        end

      {:ok, live, _html} = live(conn, ~p"/feed")

      # Over several reshuffles the union of shown permalinks must exceed the 5
      # shown at once — a fixed pick never would.
      shown =
        Enum.reduce(1..12, MapSet.new(), fn _i, acc ->
          live |> element("#discover-reshuffle") |> render_click()

          pool
          |> Enum.filter(fn {author, post} ->
            has_element?(live, ~s(#discover-posts a[href="/#{author.username}/posts/#{post.id}"]))
          end)
          |> Enum.reduce(acc, fn {_author, post}, acc -> MapSet.put(acc, post.id) end)
        end)

      assert MapSet.size(shown) > 5
    end

    test "the periodic suggestions refresh redraws the posts rail too", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      author = other_user(first_name: "New", last_name: "Voice")
      {:ok, post} = Posts.create_post(author, %{body: "still discoverable"})

      {:ok, live, _html} = live(conn, ~p"/feed")

      assert has_element?(
               live,
               ~s(#discover-posts a[href="/#{author.username}/posts/#{post.id}"])
             )

      send(live.pid, :refresh_suggestions)
      _ = render(live)

      assert has_element?(
               live,
               ~s(#discover-posts a[href="/#{author.username}/posts/#{post.id}"])
             )
    end
  end

  describe "other formats card" do
    test "links to the feed's own agent siblings on desktop and mobile", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")

      # Desktop rail copy + the md:hidden bottom copy, both pointing at the
      # feed's own formats (/feed.md etc.) — the viewer's timeline in another
      # format, not their profile, and no vCard (a feed has no contact card).
      for id <- ["feed-other-formats", "feed-other-formats-mobile"] do
        assert has_element?(live, ~s(##{id} a[href="/feed.md"]))
        assert has_element?(live, ~s(##{id} a[href="/feed.json"]))
        refute has_element?(live, ~s(##{id} a[href$=".vcf"]))
      end
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

    test "Edit drops out of the menu once the edit window has run out", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "old words"})

      at =
        NaiveDateTime.add(
          NaiveDateTime.utc_now(:second),
          -(Posts.edit_window_minutes() + 1) * 60
        )

      Repo.update_all(from(p in Vutuv.Posts.Post, where: p.id == ^post.id),
        set: [inserted_at: at]
      )

      {:ok, live, _html} = live(conn, ~p"/feed")

      # Delete stays: only the edit closes (issue #1023).
      refute has_element?(live, "#post-menu-post-#{post.id} a[href='/posts/#{post.id}/edit']")
      assert has_element?(live, "#post-menu-post-#{post.id} a[data-method='delete']")
    end
  end

  describe "mute from the feed" do
    test "a followed author's post carries a Mute toggle wired to the mute route", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      {:ok, follow} = Vutuv.Social.follow(user, friend.id)
      {:ok, post} = Posts.create_post(friend, %{body: "noise"})

      {:ok, live, _html} = live(conn, ~p"/feed")

      # The non-author ⋯ menu carries the Mute toggle on the viewer's follow edge.
      assert has_element?(
               live,
               "#post-report-post-#{post.id} a[href='/follows/#{follow.id}/mute'][data-method='put']"
             )
    end

    test "no Mute toggle on your own post", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "mine"})

      {:ok, live, _html} = live(conn, ~p"/feed")

      refute has_element?(live, "a[href*='/mute']")
      assert has_element?(live, "#post-menu-post-#{post.id}")
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

    test "a blocked author's post never reaches the pill via a third-party repost", %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)
      blocked_author = other_user()
      reposter = other_user()

      {:ok, _} = Vutuv.Social.block_user(viewer, blocked_author)
      insert(:follow, follower: viewer, followee: reposter)

      {:ok, post} = Posts.create_post(blocked_author, %{body: "blocked words"})

      {:ok, live, _html} = live(conn, ~p"/feed")

      :ok = Posts.repost_post(reposter, post)
      _ = :sys.get_state(live.pid)

      html = render(live)
      refute html =~ "Show 1 new post"
      refute html =~ "blocked words"
    end

    test "deleting a shown post removes it from the open feed", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)
      {:ok, post} = Posts.create_post(friend, %{body: "ephemeral"})

      {:ok, live, html} = live(conn, ~p"/feed")
      assert html =~ "ephemeral"

      {:ok, _} = Posts.delete_post(post)
      _ = :sys.get_state(live.pid)
      refute render(live) =~ "ephemeral"
    end

    test "a post deleted while behind the pill never surfaces", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      {:ok, live, _html} = live(conn, ~p"/feed")
      {:ok, post} = Posts.create_post(friend, %{body: "fleeting"})
      assert render(live) =~ "Show 1 new post"

      {:ok, _} = Posts.delete_post(post)
      _ = :sys.get_state(live.pid)
      html = render(live)
      refute html =~ "Show 1 new post"
      refute html =~ "fleeting"
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

  describe "midnight day-change refresh" do
    # Backdate a post one German calendar day so its stamp is the "yesterday"
    # form regardless of when the suite runs. Noon keeps the Berlin day clear of
    # either midnight.
    defp backdate_to_yesterday!(post) do
      yesterday = NaiveDateTime.new!(Date.add(Vutuv.BerlinTime.today(), -1), ~T[12:00:00])
      post |> Ecto.Changeset.change(inserted_at: yesterday) |> Vutuv.Repo.update!()
    end

    test "a post from yesterday renders the 'Gestern'/'Yesterday' stamp", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "words from the prior day"})
      backdate_to_yesterday!(post)

      {:ok, _live, html} = live(conn, ~p"/feed")

      assert html =~ "words from the prior day"
      assert html =~ ~r/Gestern|Yesterday/
    end

    test "a :day_changed tick re-renders the feed without dropping shown posts", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, _} = Posts.create_post(user, %{body: "still here"})

      {:ok, live, _html} = live(conn, ~p"/feed")
      assert render(live) =~ "still here"

      # The DayClock fires this at Berlin midnight; the feed re-streams its
      # retained entries in place, so every post survives the refresh.
      send(live.pid, :day_changed)
      _ = :sys.get_state(live.pid)
      assert render(live) =~ "still here"
    end
  end

  describe "preview truncation" do
    test "clamps the body and ships an in-place expand button (no word count)", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      # 40 words, well under the 1000-char source limit, so the source is NOT
      # cut server-side: the whole body is in the DOM and the only clipping is
      # the CSS line clamp, which only the browser can measure. "Read more" is
      # therefore an in-place expand button (the full text is present) that ships
      # invisible until the PostPreviewClamp JS confirms the body overflows.
      body = String.duplicate("lorem ", 40) |> String.trim()
      {:ok, _post} = Posts.create_post(user, %{body: body})

      {:ok, live, _html} = live(conn, ~p"/feed")

      # The clamp is the `.post-clamp` class; the per-breakpoint line budget
      # (default 6 desktop / 8 mobile) lives in CSS custom properties, so a
      # default reader carries no inline `style` override on the body.
      assert has_element?(live, "#feed-posts [data-clamp-body].post-clamp")
      refute has_element?(live, "#feed-posts [data-clamp-body][style]")

      # A non-truncated preview expands in place: "Read more" is a toggle
      # `<button data-post-expand>` (not a link to the permalink), carrying both
      # labels so the JS can swap "Read more" ⇄ "Show less" without a round-trip.
      assert has_element?(
               live,
               ~s(#feed-posts button[data-read-more][data-post-expand][aria-expanded="false"]),
               "Read more"
             )

      refute has_element?(live, ~s(#feed-posts a[data-read-more]))

      # The control's visibility is driven entirely by the wrapper's
      # `is-clamped` / `is-expanded` state (component CSS), not by competing
      # `hidden`/`inline-block` display utilities on the element — so the #880
      # two-display-utilities trap cannot recur. A css-only clamp is unknown to
      # the server, so the wrapper is NOT `is-clamped` until the JS confirms it.
      refute has_element?(live, "#feed-posts .post-preview.is-clamped")

      # Issue #880: the word-count hint is gone — it was meaningless and even
      # rendered on posts short enough to be fully visible.
      refute render(live) =~ "words total"
    end

    test "a long post also expands in place (whole body shipped, no link-out)", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      # ~1500 chars, well past the old ~1000-char source cut. The whole body is
      # now shipped to the DOM (the `.post-clamp` CSS does the visual cut and the
      # in-place expand reveals the rest), so a long post behaves exactly like a
      # short one: "Read more" is the toggle button, never a link that navigates
      # away. A distinctive tail proves the full body — past the old cut — is
      # present.
      tail = "distinctivetailmarker"
      body = (String.duplicate("lorem ", 250) |> String.trim()) <> " " <> tail
      {:ok, post} = Posts.create_post(user, %{body: body})

      {:ok, live, _html} = live(conn, ~p"/feed")

      # The whole body is in the DOM — the source is no longer truncated.
      assert render(live) =~ tail
      assert has_element?(live, "#feed-posts [data-clamp-body].post-clamp")

      # In-place expand button, and NO link-out affordance anywhere.
      assert has_element?(
               live,
               ~s(#feed-posts button[data-read-more][data-post-expand][aria-expanded="false"]),
               "Read more"
             )

      refute has_element?(live, ~s(#feed-posts a[data-read-more]))
      refute has_element?(live, ~s(#feed-posts a[href="#{Posts.path(post)}"][data-read-more]))

      # A css-only clamp is unknown to the server, so the wrapper is NOT
      # `is-clamped` until the JS confirms the overflow (same as a short post).
      refute has_element?(live, "#feed-posts .post-preview.is-clamped")
      refute render(live) =~ "words total"
    end

    test "a one-line post ships an invisible expand button (JS decides) and no word count", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      {:ok, _post} = Posts.create_post(user, %{body: "just a line"})

      {:ok, live, _html} = live(conn, ~p"/feed")

      # The expand button is present (JS decides visibility) but the short body
      # is never source-truncated, so the wrapper is not `is-clamped` and the
      # control stays hidden until the JS measures an overflow (it won't here).
      assert has_element?(live, "#feed-posts button[data-read-more][data-post-expand]")
      refute has_element?(live, "#feed-posts .post-preview.is-clamped")

      refute render(live) =~ "words total"
    end
  end

  describe "single-image layout" do
    # A pending image (post: nil) owned by the author, attached to a fresh post
    # via create_post/2's image_ids — the real upload path stores dimensions the
    # same way. Dimensions are the whole point here, so each test picks its own.
    defp post_with_image(user, body, width, height, token) do
      image =
        insert(:post_image, user: user, post: nil, width: width, height: height, token: token)

      {:ok, post} = Posts.create_post(user, %{body: body, image_ids: [image.id]})
      post
    end

    test "a roughly square image floats beside the text (wrap layout), not a full-width crop", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      # 736×678 ≈ 1.09 — the near-square GitHub code card that prompted this. At
      # full column width its natural height overruns the max-h cap and object-cover
      # crops it to a middle band; floated in a third the text wraps around it and
      # it shows in full.
      post_with_image(user, "A near-square screenshot", 736, 678, "sqtok")

      {:ok, _live, html} = live(conn, ~p"/feed")

      # The float-wrap layout: the image floats and the body clamps by height so
      # the text flows around AND below it (no dead column).
      assert html =~ "float-right"
      assert html =~ "post-clamp--wrap"
      assert html =~ "/post_images/sqtok/feed.avif"
      # It must NOT also render the cropping full-width single-image variant.
      refute html =~ "max-h-96"
    end

    test "the image floats first (before the text/tags) so the text wraps around it", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      image = insert(:post_image, user: user, post: nil, width: 736, height: 678, token: "sqtag")

      {:ok, _post} =
        Posts.create_post(user, %{
          body: "square with a tag",
          image_ids: [image.id],
          tags: "elixir"
        })

      {:ok, _live, html} = live(conn, ~p"/feed")

      # For the text to wrap around it, the floated image is the clamp block's
      # first child — DOM-ordered *before* the body text and the tag chip (which
      # follow it), not in a full-width row after the whole block.
      {img_pos, _} = :binary.match(html, "/post_images/sqtag/feed.avif")
      {tag_pos, _} = :binary.match(html, "/tags/elixir")

      assert img_pos < tag_pos,
             "expected the floated image to render before (be wrapped by) the text and tag"
    end

    test "a clearly landscape image keeps the full-width layout", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # 1200×600 = 2.0 — a wide banner reads fine full-width (short, uncropped),
      # so it must not be squeezed into a third beside the text.
      post_with_image(user, "A wide banner", 1200, 600, "widetok")

      {:ok, _live, html} = live(conn, ~p"/feed")

      refute html =~ "post-clamp--wrap"
      assert html =~ "max-h-96"
      assert html =~ "/post_images/widetok/feed.avif"
    end

    test "a squarish image with no body text stays full-width (no empty text column)", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      # Photo-only post (blank body is allowed with an attached image): there is
      # no text to wrap around it, so the float layout makes no sense.
      post_with_image(user, "", 700, 680, "notxttok")

      {:ok, _live, html} = live(conn, ~p"/feed")

      refute html =~ "post-clamp--wrap"
      assert html =~ "/post_images/notxttok/feed.avif"
    end
  end

  describe "multi-image gallery" do
    test "tiles images at their natural aspect ratio (no 4:3 crop), like the permalink", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      one = insert(:post_image, user: user, post: nil, token: "galone")
      two = insert(:post_image, user: user, post: nil, token: "galtwo")

      {:ok, _post} = Posts.create_post(user, %{body: "two shots", image_ids: [one.id, two.id]})

      {:ok, live, _html} = live(conn, ~p"/feed")
      feed_html = live |> element("#feed-posts") |> render()

      # Both attachments render at feed size…
      assert feed_html =~ "/post_images/galone/feed.avif"
      assert feed_html =~ "/post_images/galtwo/feed.avif"
      # …uncropped. The preview grid used to force every tile to `aspect-[4/3]`,
      # chopping a screenshot or panorama down to a middle band — the feed looked
      # worse than the permalink, which shows the images whole. The feed gallery
      # now shares the permalink's rendering (natural aspect, no crop).
      refute feed_html =~ "aspect-[4/3]"
      # …tiling 1-up on phones, 2-up on sm+ — the permalink's responsive grid,
      # not the old always-two-column mobile layout that shrank each tile.
      assert feed_html =~ "sm:grid-cols-2"
    end
  end
end
