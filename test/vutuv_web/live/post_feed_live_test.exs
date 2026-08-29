defmodule VutuvWeb.PostFeedLiveTest do
  @moduledoc """
  The /feed LiveView: composer round trips (body, tags, public-by-default posts
  and the deny "Hide from…" sheet), live prepend of own posts, the "Show N new
  posts" pill for followed authors (visibility-checked), and cursor pagination.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Activity
  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage

  defp other_user(attrs \\ []), do: insert(:user, Keyword.merge([email_confirmed?: true], attrs))

  # How many timeline rows are drawn but hidden — the waiting posts. Counted off
  # the row wrapper's own class, so it cannot catch a `hidden` somewhere inside
  # a card.
  # Timeline rows currently drawn but hidden (the pending-arrival valve).
  #
  # Two lookaheads rather than one literal `class="…" hidden`: that spelling
  # asserted the two attributes were ADJACENT in the rendered tag, so adding any
  # third attribute to the row between them (the day marker's `data-post-day`)
  # dropped the count to zero while the feed behaved perfectly. Attribute order
  # is HEEx's business, not this test's. `[\s=>]` because a boolean attribute
  # renders as `hidden=""`, not bare `hidden`.
  defp hidden_rows(html) do
    ~r/<div(?=[^>]*class="py-4 first:pt-0 last:pb-0")(?=[^>]*\shidden[\s=>])[^>]*>/
    |> Regex.scan(html)
    |> length()
  end

  # Where `text` first shows up in the rendered feed — how the thread tests
  # assert reading order without parsing the whole card tree.
  defp position(html, text) do
    case :binary.match(html, text) do
      {at, _} -> at
      :nomatch -> flunk("#{inspect(text)} is not on the page")
    end
  end

  describe "quoting a passage into a reply (#1114)" do
    test "a card names its own Reply control, so a selection can ride along", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, _post} = Posts.create_post(user, %{body: "a passage worth answering"})

      {:ok, _live, html} = live(conn, ~p"/feed")

      # The card points at the Reply control by id and marks the prose the
      # selection has to come from — app.js needs both halves to fire.
      assert [reply_id] = Regex.run(~r/data-quote-reply="([^"]+)"/, html, capture: :all_but_first)
      assert html =~ ~s(id="#{reply_id}")
      assert html =~ "data-post-body"
    end

    test "a restricted post is not armed — its Reply control is a dead span", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, _post} =
        Posts.create_post(user, %{
          body: "not for everyone",
          denials: [%{"wildcard" => "logged_out"}]
        })

      {:ok, _live, html} = live(conn, ~p"/feed")

      assert html =~ "not for everyone"
      refute html =~ "data-quote-reply"
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

    test "the stored draft is read once per mount, not by feed and composer both", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      :ok = Posts.save_draft(user, nil, %{body: "half-typed"})

      {conn, draft_queries} =
        Vutuv.QueryCounter.count_queries(
          fn -> get(conn, ~p"/feed") end,
          matching: ~r/FROM "post_drafts"/
        )

      # The feed reads the draft to decide whether the composer panel opens and
      # hands it to the composer, which must not run the same query again.
      assert html_response(conn, 200) =~ "composer-panel"
      assert draft_queries == 1, "expected one post_drafts read per mount, got #{draft_queries}"
    end

    test "the connected mount reuses the dead render's work (handoff)", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)
      {:ok, _} = Posts.create_post(friend, %{body: "a handoff post from my friend"})

      # The dead render stashes the computed page; the connect takes it. This
      # module is sync (ConnCase default), which count_queries_global needs.
      conn = get(conn, ~p"/feed")
      assert html_response(conn, 200) =~ "a handoff post from my friend"

      {{:ok, _view, hit_html}, hit} =
        Vutuv.QueryCounter.count_queries_global(fn -> live(conn) end)

      assert hit_html =~ "a handoff post from my friend"

      # Single-use: a second connect finds the stash consumed and full-loads.
      {{:ok, _view, miss_html}, miss} =
        Vutuv.QueryCounter.count_queries_global(fn -> live(conn) end)

      assert miss_html =~ "a handoff post from my friend"

      # The absolute bound is a smoke alarm, not the proof — it counts every
      # query the connect runs, so a new sidebar raises it without saying
      # anything about the handoff. The filter band added a fixed handful (its
      # account rows, the muted ones, the servers, the follow count, the two
      # source totals and the member's word/tag rules), which is why this reads
      # 20 rather than the 15 it did before v7.371. What actually proves the
      # stash was used is the comparison below: the same page, with and without
      # it, is immune to whatever else the rail costs.
      #
      # It also guards the feed calendar's laziness, which is what made this go
      # red once: computing the heatmap (a nine-source union over a month) and
      # its floor check on every mount, for a grid that ships folded and most
      # readers never open, took a connected mount from 18 queries to 28. The
      # counts are bought by unfolding now, not by arriving.
      assert hit <= 20, "handoff-hit feed connect ran #{hit} queries; the handoff was not used"

      assert miss >= hit + 10,
             "consumed-stash feed connect ran #{miss} vs hit #{hit}; full-load fallback missing?"
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
      # The stranger's post stays out of the timeline: nobody here follows them.
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

    test "a context parent that is itself a reply says who IT answers", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      # Two members the viewer does not follow hold a conversation and the viewer
      # answers the second of them. Only that answer is on this feed, so the
      # chain stops one step up and the block's topmost card is a post pulled in
      # purely as context — itself an answer to a post that is not on the page.
      opener = other_user()
      middle = other_user()
      {:ok, root} = Posts.create_post(opener, %{body: "the post that opened it"})
      {:ok, parent} = Posts.create_reply(middle, root, %{body: "an answer to the opener"})
      {:ok, _leaf} = Posts.create_reply(user, parent, %{body: "my answer to that answer"})

      {:ok, live, _html} = live(conn, ~p"/feed")

      # It says so, rather than passing for the post that started the thread.
      assert has_element?(
               live,
               ~s(#feed-posts [data-reply-banner="parent"] a[href="#{Posts.path(root)}"]),
               "@#{opener.username}"
             )

      # The viewer's own reply keeps its banner off — the card above it already
      # shows that relationship.
      refute has_element?(
               live,
               ~s(#feed-posts [data-reply-banner] a[href="#{Posts.path(parent)}"])
             )
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
      assert has_element?(live, ~s(#feed-posts[data-filter-list]))
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

      # The normal upload feature stays: the add tile and per-image remove
      # control are still there (with a photo attached, the grid's tile owns
      # the picker).
      assert render(live) =~ "Add photos"
      assert has_element?(live, ~s([phx-click="remove-image"]))

      # The completed upload is announced to the editor hook (which decides
      # whether this file was dropped/pasted into the prose and should be
      # inserted at the cursor).
      assert_push_event(live, "mde-image-uploaded", %{
        editor: "composer-body",
        name: "photo.png",
        url: "/post_images/" <> _
      })

      # "Insert into text" lives in the photo's own panel (issue #1104): the
      # tile is too small for four controls, and inline placement is a rarer
      # choice than removing or reordering a photo. Clicking it still tells the
      # editor hook to place the image at the cursor.
      [image] = Vutuv.Repo.all(PostImage)
      refute has_element?(live, ~s([phx-click="insert-inline"]))

      # The scrim's ⚙ specifically — the tile's img opens the panel too, so a
      # bare [phx-click=photo-open] selector matches two elements.
      live
      |> element(~s(button[phx-click="photo-open"][phx-value-id="#{image.id}"]))
      |> render_click()

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
      # the float), so they come before the "Read more" control that follows the
      # block and before the unreferenced-attachment tile row — a tall float
      # used to push them below the whole picture…
      {tag_pos, _} = :binary.match(html, ~s(href="/tags/elixir"))
      {more_pos, _} = :binary.match(html, "post-preview__more")
      {gallery_pos, _} = :binary.match(html, "/post_images/tagfeedgal/feed.avif")
      assert tag_pos < more_pos
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

    test "one tag too many is refused instead of being dropped", %{conn: conn} do
      {conn, author} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      tags = Enum.map_join(1..(Posts.max_tags_per_post() + 1), ", ", &"cap-tag-#{&1}")

      html =
        live
        |> form("#composer-form", %{"post" => %{"body" => "one tag too many", "tags" => tags}})
        |> render_submit()

      # Issue #1237: the extra tags used to disappear on the way to a published
      # post. Now the composer stays open with the post intact and says why.
      assert has_element?(live, "#composer-error")
      assert html =~ "at most #{Posts.max_tags_per_post()}"
      refute html =~ "%{max}"
      refute Repo.exists?(from(p in Vutuv.Posts.Post, where: p.user_id == ^author.id))
    end

    test "the tag cap is explained in German for a German visitor", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      user |> Ecto.Changeset.change(%{locale: nil}) |> Vutuv.Repo.update!()

      {:ok, live, _html} =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> live(~p"/feed")

      tags = Enum.map_join(1..(Posts.max_tags_per_post() + 1), ", ", &"cap-tag-de-#{&1}")

      html =
        live
        |> form("#composer-form", %{"post" => %{"body" => "ein Tag zu viel", "tags" => tags}})
        |> render_submit()

      assert html =~ "höchstens #{Posts.max_tags_per_post()} Tags"
      refute html =~ "%{max}"
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
      assert has_element?(live, "#composer-trigger.flex")
      assert has_element?(live, "#composer-panel.hidden")
      assert has_element?(live, "#composer-panel.hidden #composer-body")

      live |> element("#open-composer") |> render_click()

      # Revealed: the panel is no longer hidden and the trigger is merely
      # hidden — it must stay IN the DOM (issue #1200's shape: a conditional
      # sibling above the editor makes morphdom relocate the panel, which blurs
      # the contenteditable), and its two display classes stay mutually
      # exclusive so `hidden` cannot lose the cascade (issue #880).
      refute has_element?(live, "#composer-panel.hidden")
      assert has_element?(live, "#composer-trigger.hidden")
      refute has_element?(live, "#composer-trigger.flex")
    end

    test "the composer submits on Cmd/Ctrl+Enter like the message composer", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      # Issue #1196: data-mde-submit="cmd-enter" opts the shared Milkdown editor
      # into the one Cmd/Ctrl+Enter handler in assets/js/markdown_editor.js —
      # the same attribute the message composer passes, so both composers share
      # the wiring instead of growing their own key handling.
      assert has_element?(live, ~s(#composer-body[data-mde-submit="cmd-enter"]))
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
      assert has_element?(live, "#composer-trigger.hidden")

      # The composer's corner ✕ (feed compose only) bubbles up to the feed and
      # collapses the panel again.
      assert has_element?(live, ~s(#composer-form button[phx-click="close-composer"]))

      live |> element(~s(#composer-form button[phx-click="close-composer"])) |> render_click()

      assert has_element?(live, "#composer-trigger.flex")
      assert has_element?(live, "#composer-panel.hidden")
    end

    test "posting collapses the composer back to the button", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      live |> element("#open-composer") |> render_click()
      assert has_element?(live, "#composer-trigger.hidden")

      live
      |> form("#composer-form", %{"post" => %{"body" => "first words"}})
      |> render_submit()

      # The viewer's own post arrived below, so the composer collapsed again.
      assert has_element?(live, "#composer-trigger.flex")
      assert has_element?(live, "#composer-panel.hidden")
    end

    test "a half-typed draft brings the composer back after a reconnect", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      # What a reconnect does (issue #1130): the feed re-mounts, so the composer
      # starts collapsed again, while LiveView's form recovery replays the
      # composer's phx-change with the half-typed text still sitting in the DOM.
      # This is that second half — a collapsed feed receiving a `validate` that
      # carries a body. The draft has to bring the panel back, or the author
      # returns to their tab and finds the form gone with the text inside it.
      assert has_element?(live, "#composer-panel.hidden")

      live
      |> form("#composer-form", %{"post" => %{"body" => "half-typed draft"}})
      |> render_change()

      refute has_element?(live, "#composer-panel.hidden")
      assert has_element?(live, "#composer-trigger.hidden")
    end

    test "typed tags alone bring the composer back too", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      live
      |> form("#composer-form", %{"post" => %{"body" => "", "tags" => "elixir"}})
      |> render_change()

      refute has_element?(live, "#composer-panel.hidden")
    end

    test "an empty composer stays collapsed", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      # Nothing typed, nothing to rescue: a recovered empty form must not pop
      # the composer open under a reader who never opened it.
      live
      |> form("#composer-form", %{"post" => %{"body" => "", "tags" => ""}})
      |> render_change()

      assert has_element?(live, "#composer-panel.hidden")
      assert has_element?(live, "#composer-trigger.flex")
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

  describe "a page's repost (issue #1410)" do
    test "the banner names the page like a member", %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)
      author = other_user()
      page = insert(:organization, name: "Bannerwerk GmbH")

      Repo.insert!(%Vutuv.Social.Follow{
        follower_id: viewer.id,
        followee_organization_id: page.id
      })

      {:ok, post} = Posts.create_post(author, %{body: "Reshared by a page."})
      Repo.insert!(%Vutuv.Posts.PostRepost{post_id: post.id, organization_id: page.id})

      {:ok, _live, html} = live(conn, ~p"/feed")

      assert html =~ "Reposted by Bannerwerk GmbH"
      assert html =~ ~s(href="/organizations/#{page.slug}")
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
    test "a followed author's new post is drawn hidden and shown by the pill", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      {:ok, live, _html} = live(conn, ~p"/feed")

      {:ok, post} = Posts.create_post(friend, %{body: "breaking news"})

      html = render(live)
      assert html =~ "Show 1 new post"

      # The card is drawn straight away so that showing it costs no round trip,
      # and `hidden` is the whole reason the timeline still does not move under
      # the reader — the browser's own stylesheet drops the row until the press
      # takes the attribute off, in the browser.
      assert has_element?(live, "#feed-posts [hidden][id*='#{post.id}']")

      live |> element("#show-new-posts") |> render_click()

      # The press is client-side, so the attribute is still in this DOM — what
      # the server owes is that it never puts it back. A restream is the
      # cheapest way to make it re-render the row and prove that.
      refute has_element?(live, "#show-new-posts")
      send(live.pid, :day_changed)
      assert has_element?(live, "#feed-posts [id*='#{post.id}']")
      refute has_element?(live, "#feed-posts > [hidden]")
      assert render(live) =~ "breaking news"
    end

    test "beside a quote the pill's visible label is only the prefix to it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      {:ok, live, _html} = live(conn, ~p"/feed")
      {:ok, _} = Posts.create_post(friend, %{body: "breaking news"})

      pill = live |> element("#show-new-posts") |> render()

      # On a phone the whole sentence took the line and left the quote three
      # letters, so beside a quote the label shrinks to what introduces it.
      assert pill =~ "New:"
      assert pill =~ "breaking news"

      # It is not lost, and not doubled either: it is said once, where a screen
      # reader hears it and no width is spent on it.
      assert pill =~ ~r{class="sr-only">Show 1 new post}
      assert length(Regex.scan(~r/Show 1 new post/, pill)) == 1

      # More than one and the count moves into the label, still short.
      for n <- 2..3, do: {:ok, _} = Posts.create_post(friend, %{body: "arrival #{n}"})

      pill = live |> element("#show-new-posts") |> render()
      assert pill =~ "New (3):"
      assert pill =~ ~r{class="sr-only">Show 3 new posts}
    end

    test "with nothing to quote the pill says the whole sentence", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      {:ok, live, _html} = live(conn, ~p"/feed")

      # A photo without a caption: no line to quote, so a bare "New:" would
      # hang its colon on nothing.
      image = insert(:post_image, user: friend)
      {:ok, _} = Posts.create_post(friend, %{body: "", image_ids: [image.id]})

      pill = live |> element("#show-new-posts") |> render()

      assert pill =~ "Show 1 new post"
      refute pill =~ "New:"
      # Said once: with no prefix to introduce there is no second, hidden copy.
      assert length(Regex.scan(~r/Show 1 new post/, pill)) == 1
    end

    test "a tab left open for days stops drawing and starts counting", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      {:ok, live, _html} = live(conn, ~p"/feed")

      # Two past the cap of 25. The valve is what keeps a feed left open over a
      # weekend from filling the document with thousands of hidden cards.
      {:ok, first} = Posts.create_post(friend, %{body: "arrival number 1"})
      for n <- 2..27, do: {:ok, _} = Posts.create_post(friend, %{body: "arrival number #{n}"})

      html = render(live)

      # Drawn: the newest 25. Counted: all 27.
      assert hidden_rows(html) == 25
      assert html =~ "Show 27 posts in the feed"

      # And the two the valve turned away left no row behind.
      refute has_element?(live, "#feed-posts [id*='#{first.id}']")

      # The control drops the browser-side reveal, because there is no longer a
      # row for every post it promises — it is the plain event, and the server
      # answers with a page.
      assert has_element?(live, "#unread-insert[phx-click='show-new']")

      live |> element("#unread-insert") |> render_click()

      assert render(live) =~ "arrival number 27"
      refute has_element?(live, "#feed-posts > [hidden]")
      refute has_element?(live, "#unread-posts")
    end

    test "under the cap the press stays a browser-side reveal", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      {:ok, live, _html} = live(conn, ~p"/feed")
      {:ok, _} = Posts.create_post(friend, %{body: "just the one"})

      # A JS command chain, not the bare event: the reader waits for nothing.
      refute has_element?(live, "#unread-insert[phx-click='show-new']")
      assert has_element?(live, "#unread-insert")
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

  describe "revealing pending posts clears their notifications" do
    # Clicking "Show N new posts" is the member choosing to look at exactly
    # those posts, so a notification whose subject is one of them (the answer
    # to their post, an answer elsewhere in their thread, the post naming
    # them) must stop counting as unread the moment the pill unfolds — the
    # bell badge recounts over the existing :notifications_changed signal.
    test "a pending reply's unread notification clears on reveal", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)
      {:ok, mine} = Posts.create_post(user, %{body: "my open question"})

      {:ok, live, _html} = live(conn, ~p"/feed")

      # A fresh registration already carries its own welcome notification, so
      # the tests count relative to that baseline.
      base = Activity.unread_notification_count(user.id)

      {:ok, _reply} = Posts.create_reply(friend, mine, %{body: "the answer, live"})

      assert render(live) =~ "Show 1 new post"
      assert Activity.unread_notification_count(user.id) == base + 1

      live |> element("#show-new-posts") |> render_click()

      assert render(live) =~ "the answer, live"
      assert Activity.unread_notification_count(user.id) == base
    end

    test "a pending mention's unread notification clears on reveal", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)

      {:ok, live, _html} = live(conn, ~p"/feed")
      base = Activity.unread_notification_count(user.id)

      {:ok, _post} = Posts.create_post(friend, %{body: "Ask @#{user.username} about it."})

      assert render(live) =~ "Show 1 new post"
      assert Activity.unread_notification_count(user.id) == base + 1

      live |> element("#show-new-posts") |> render_click()

      assert Activity.unread_notification_count(user.id) == base
    end

    test "revealing leaves notifications about other posts unread", %{conn: conn} do
      # The reveal marks exactly the revealed posts — a reply from another
      # network (a fediverse Note on the member's post) never sits behind the
      # pill (remote replies live on the post's thread page), so revealing an
      # unrelated pending post must not swallow its notification.
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)
      {:ok, mine} = Posts.create_post(user, %{body: "federated far and wide"})
      insert(:note, post: mine)

      {:ok, live, _html} = live(conn, ~p"/feed")

      # Baseline includes the welcome notification and the fediverse reply.
      base = Activity.unread_notification_count(user.id)

      {:ok, _post} = Posts.create_post(friend, %{body: "unrelated news"})

      assert render(live) =~ "Show 1 new post"
      assert Activity.unread_notification_count(user.id) == base

      live |> element("#show-new-posts") |> render_click()

      assert render(live) =~ "unrelated news"
      assert Activity.unread_notification_count(user.id) == base
    end
  end

  describe "pagination" do
    test "loads older posts on demand", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      for n <- 1..41, do: {:ok, _} = Posts.create_post(user, %{body: "post number #{n}"})

      {:ok, live, html} = live(conn, ~p"/feed")

      # Forty on arrival, twenty per page after that: the first screenful is
      # the one nobody asked for, so it is the one that has to last.
      assert html =~ "post number 41"
      assert html =~ "post number 2<"
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
      # It must NOT also render the full-width single-image variant.
      refute html =~ "data-photo-fit"
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

    test "a clearly landscape image keeps the full-width layout, uncropped", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # 1200×600 = 2.0 — a wide banner reads fine full-width (short, uncropped),
      # so it must not be squeezed into a third beside the text.
      post_with_image(user, "A wide banner", 1200, 600, "widetok")

      {:ok, _live, html} = live(conn, ~p"/feed")

      refute html =~ "post-clamp--wrap"
      assert html =~ "/post_images/widetok/feed.avif"
      # 2:1 is still an ordinary shape, so it is shown whole (issue #1104):
      # a single photo is bounded in height, never cut down to a middle band.
      assert html =~ ~s(data-photo-fit="whole")
      refute html =~ "object-cover"
    end

    test "a wide screenshot is shown whole, not cut off at the right", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # 1572×424 = 3.7:1, the shape that reopened this: a screenshot of a news
      # teaser card whose right-hand third carries the headline and the teaser
      # text. Cropping it to 2:1 threw exactly that away in the feed while the
      # permalink showed it, so the two read as different posts.
      post_with_image(user, "A teaser screenshot", 1572, 424, "shottok")

      {:ok, _live, html} = live(conn, ~p"/feed")

      assert html =~ ~s(data-photo-fit="whole")
      refute html =~ "object-cover"
    end

    test "even a stitched panorama is shown whole, only flat", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # 6000×1000 = 6:1. The column bounds the width, so this is merely a flat
      # strip — it costs the timeline nothing and keeps every pixel.
      post_with_image(user, "A panorama", 6000, 1000, "panotok")

      {:ok, _live, html} = live(conn, ~p"/feed")

      assert html =~ ~s(data-photo-fit="whole")
      refute html =~ "object-cover"
    end

    test "a tall tower is cropped to an ordinary frame instead of a scroll", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # 1000×6000 = 1:6. Shown whole at column width this runs several screens
      # down the timeline, so it is the one single-photo case that still crops.
      post_with_image(user, "A tall infographic", 1000, 6000, "towertok")

      {:ok, _live, html} = live(conn, ~p"/feed")

      assert html =~ ~s(data-photo-fit="crop")
      assert html =~ "aspect-ratio: 3 / 4"
      assert html =~ "object-cover"
    end

    test "a tall portrait is shown whole rather than cut off top and bottom", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # 1080×1920 = 9:16, what a phone hands you by default. The old card put
      # every single photo in a 24rem object-cover box, which cut this one's
      # head and feet off.
      post_with_image(user, "A phone portrait", 1080, 1920, "porttok")

      {:ok, _live, html} = live(conn, ~p"/feed")

      assert html =~ ~s(data-photo-fit="whole")
      refute html =~ "object-cover"
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

  # The feed's multi-photo rendering is the bento mosaic (issue #1104): a
  # glance of capped height, laid out from the photos' own shapes. The
  # permalink is where they are shown whole — see the mosaic geometry in
  # `mosaic_layout_test.exs` and the permalink gallery in the thread tests.
  describe "multi-image gallery" do
    test "lays several photos out as one capped mosaic", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      one = insert(:post_image, user: user, post: nil, token: "galone")
      two = insert(:post_image, user: user, post: nil, token: "galtwo")

      {:ok, post} = Posts.create_post(user, %{body: "two shots", image_ids: [one.id, two.id]})

      {:ok, live, _html} = live(conn, ~p"/feed")
      feed_html = live |> element("#feed-posts") |> render()

      # Both attachments render at feed size…
      assert feed_html =~ "/post_images/galone/feed.avif"
      assert feed_html =~ "/post_images/galtwo/feed.avif"
      # …as one mosaic of a bounded height, so a photo post costs the timeline
      # no more room than a snapshot.
      assert feed_html =~ ~s(data-post-mosaic="2")
      assert feed_html =~ "max-height: 44rem"
      # The whole mosaic is one link to the post: a tile is a glance, and the
      # photos themselves are shown (and opened in the lightbox) on the
      # permalink.
      assert feed_html =~ Posts.path(post)
      # The old blanket `aspect-[4/3]` tile crop is gone for good — the frame
      # follows the photos now.
      refute feed_html =~ "aspect-[4/3]"
    end

    test "a sixth photo and beyond fold into a count rather than more tiles", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      images =
        for index <- 1..7, do: insert(:post_image, user: user, post: nil, token: "gal#{index}")

      {:ok, _post} =
        Posts.create_post(user, %{body: "a set", image_ids: Enum.map(images, & &1.id)})

      {:ok, live, _html} = live(conn, ~p"/feed")
      feed_html = live |> element("#feed-posts") |> render()

      assert feed_html =~ "data-mosaic-more"
      assert feed_html =~ "+2"
      # The sixth and seventh photos are not loaded at all — the point of the
      # cap is that a photo essay does not cost seven image requests in a feed.
      refute feed_html =~ "/post_images/gal6/feed.avif"
      refute feed_html =~ "/post_images/gal7/feed.avif"
    end
  end

  # Personal content filters (issue #940): a matching post collapses to a
  # "Show anyway" line instead of vanishing, and the viewer's own posts are
  # never filtered.
  describe "content filters" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)
      %{conn: conn, user: user, friend: friend}
    end

    test "a muted keyword collapses a matching post to a placeholder", %{
      conn: conn,
      user: user,
      friend: friend
    } do
      {:ok, _} =
        Vutuv.ContentFilters.create_filter(user, %{"kind" => "keyword", "pattern" => "crypto"})

      {:ok, _} = Posts.create_post(friend, %{body: "buy crypto now"})

      {:ok, live, html} = live(conn, ~p"/feed")

      assert has_element?(live, "[data-filtered-post='crypto']")
      # The body itself is not on the page until revealed.
      refute html =~ "buy crypto now"
    end

    test "the pill never quotes a post the reader muted", %{
      conn: conn,
      user: user,
      friend: friend
    } do
      {:ok, _} =
        Vutuv.ContentFilters.create_filter(user, %{"kind" => "keyword", "pattern" => "crypto"})

      {:ok, live, _html} = live(conn, ~p"/feed")
      {:ok, _} = Posts.create_post(friend, %{body: "buy crypto now"})

      pill = live |> element("#show-new-posts") |> render()

      # The row folds to a placeholder; a pill quoting its opening line would
      # read out the very words they muted.
      refute pill =~ "crypto"
      assert pill =~ "Show 1 new post"
    end

    test "'Show anyway' reveals the post in place", %{conn: conn, user: user, friend: friend} do
      {:ok, _} =
        Vutuv.ContentFilters.create_filter(user, %{"kind" => "keyword", "pattern" => "crypto"})

      {:ok, post} = Posts.create_post(friend, %{body: "buy crypto now"})

      {:ok, live, _html} = live(conn, ~p"/feed")

      revealed =
        live
        |> element("button[phx-click='reveal_filter'][phx-value-id='#{post.id}']")
        |> render_click()

      assert revealed =~ "buy crypto now"
    end

    test "the viewer's own matching post is never filtered", %{conn: conn, user: user} do
      {:ok, _} =
        Vutuv.ContentFilters.create_filter(user, %{"kind" => "keyword", "pattern" => "crypto"})

      {:ok, _} = Posts.create_post(user, %{body: "my own crypto thoughts"})

      {:ok, _live, html} = live(conn, ~p"/feed")

      # Own post shows in full; no placeholder swallows it.
      assert html =~ "my own crypto thoughts"
      refute html =~ "data-filtered-post"
    end

    test "the placeholder is two lines and cannot grow into a third", %{
      conn: conn,
      user: user,
      friend: friend
    } do
      # A phrase filter long enough to have wrapped the old row onto a third
      # line: the pattern sat in the flow, so the rule the member wrote decided
      # how tall the fold was (Stefan, 2026-08-29).
      sentence = "Noch ein paar der zuletzt hier besonders haeufig geteilten News"

      {:ok, _} =
        Vutuv.ContentFilters.create_filter(user, %{"kind" => "keyword", "pattern" => sentence})

      {:ok, _} =
        Posts.create_post(friend, %{
          body: "Noch ein paar der zuletzt hier besonders haeufig geteilten News heute"
        })

      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de;q=0.9")
      {:ok, live, _html} = live(conn, ~p"/feed")

      row = live |> element("[data-filtered-post]") |> render()

      # One label, and the pattern truncated beside it rather than wrapped.
      assert row =~ "Ausgeblendet:"
      refute row =~ "passt zu Ihrem Filter"
      assert row =~ "truncate"

      # And the only control shares the line with the name and the time, so the
      # row spends no line on a lone link.
      assert has_element?(
               live,
               "[data-filtered-post] div:first-child button[phx-click='reveal_filter']"
             )
    end

    test "a muted tag collapses a post carrying that tag", %{
      conn: conn,
      user: user,
      friend: friend
    } do
      {:ok, _} =
        Vutuv.ContentFilters.create_filter(user, %{"kind" => "tag", "pattern" => "crypto"})

      {:ok, _} = Posts.create_post(friend, %{body: "a neutral looking body", tags: "crypto"})

      {:ok, live, html} = live(conn, ~p"/feed")

      assert has_element?(live, "[data-filtered-post='crypto']")
      refute html =~ "a neutral looking body"
    end
  end
end
