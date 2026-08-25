defmodule VutuvWeb.FeedSourceTabsTest do
  @moduledoc """
  The /feed source tabs: All / vutuv / Fediverse.

  The two named tabs partition the timeline by what kind of post an entry
  carries, so the tests here are mostly about that split holding at its edges —
  the one source that produces both kinds (a boost, issue #1167), the live
  arrivals that never went through a query, and an installation with no
  fediverse at all.

  Not async: one test flips `:fediverse_enabled`, which is application env —
  process/node state the SQL sandbox does not roll back.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers, only: [backdate_post!: 2]

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.PostBoost
  alias Vutuv.Fediverse.PostRepost
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts
  alias Vutuv.Social

  # An account out there that nobody here follows.
  defp remote_account(handle) do
    actor = "https://social.example/users/#{handle}"

    Repo.insert!(%RemoteAccount{
      actor_uri: actor,
      host: "social.example",
      handle: handle,
      name: String.capitalize(handle),
      inbox_uri: actor <> "/inbox"
    })
  end

  # …and the same account with `user` following it.
  defp remote_account(user, handle) do
    account = remote_account(handle)

    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{handle}"
    })

    account
  end

  defp cached_post(account, body) do
    now = DateTime.utc_now(:second)
    unique = System.unique_integer([:positive])

    Repo.insert!(%RemotePost{
      remote_account_id: account.id,
      object_uri: "https://social.example/posts/#{unique}",
      origin_url: "https://social.example/@them/#{unique}",
      content_text: body,
      audience: "public",
      kind: "note",
      published_at: now,
      received_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
  end

  # A member here the viewer follows, plus a post of theirs.
  defp followed_post(viewer, body) do
    author = insert(:user, email_confirmed?: true)
    Social.follow(viewer, author.id)
    {:ok, post} = Posts.create_post(author, %{body: body})
    {author, post}
  end

  # What the **timeline** shows, which is the only part a tab governs. The
  # desktop "Suggested posts" rail draws from members the viewer does not
  # follow and renders on every tab, so a page-wide match finds a filtered-out
  # post there and reads as the filter having failed.
  defp timeline(view) do
    if has_element?(view, "#feed-posts"), do: render(element(view, "#feed-posts")), else: ""
  end

  # The tab as it is stored on the member, read fresh — the socket's own
  # `%User{}` was loaded at mount and knows nothing of what was written since.
  defp stored_tab(user), do: Repo.get!(User, user.id).feed_source

  describe "the tab bar shows only where it means something (issue #1267)" do
    test "renders the three source tabs above the timeline", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "a vutuv post")
      cached_post(remote_account(user, "them"), "written out there")

      {:ok, view, html} = live(conn, ~p"/feed")

      assert has_element?(view, "#feed-source-tabs [data-filter-tab='all']")
      assert has_element?(view, "#feed-source-tabs [data-filter-tab='vutuv']")
      assert has_element?(view, "#feed-source-tabs [data-filter-tab='fediverse']")
      assert html =~ "Fediverse"

      # "All" is where a mount opens; the tab reads as selected.
      assert has_element?(view, "[data-filter-tab='all'][aria-pressed='true']")
    end

    test "a member the fediverse never reaches gets no tabs at all", %{conn: conn} do
      # The reported bug: with nothing out there, "Fediverse" can never fill
      # and "vutuv" is just "All" again — one timeline under three names.
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "a vutuv post")

      {:ok, view, html} = live(conn, ~p"/feed")

      refute has_element?(view, "#feed-source-tabs")
      refute html =~ "Fediverse"
      # The timeline itself is untouched — this hides a control, not content.
      assert timeline(view) =~ "a vutuv post"
    end

    test "a completely empty feed shows the invitation instead of tabs", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, view, _html} = live(conn, ~p"/feed")

      refute has_element?(view, "#feed-source-tabs")
    end

    test "an installation with no fediverse gets no tabs", %{conn: conn} do
      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.put_env(:vutuv, :fediverse_enabled, true) end)

      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "a vutuv post")
      cached_post(remote_account(user, "them"), "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")

      refute has_element?(view, "#feed-source-tabs")
    end

    test "somebody here resharing a remote post is enough, with no fediverse account of one's own",
         %{conn: conn} do
      # The case a member-level flag would get wrong (issue #1166): this viewer
      # follows nobody out there and has no actor, but a member they follow
      # *here* reshared a remote post, so remote posts really are in their feed
      # and the tabs have work to do.
      {conn, user} = create_and_login_user(conn)
      sharer = insert(:user, email_confirmed?: true)
      Social.follow(user, sharer.id)

      # A cached post nobody here follows the author of.
      post = cached_post(remote_account("stranger"), "passed on by a friend")
      Repo.insert!(%PostRepost{user_id: sharer.id, remote_post_id: post.id})

      refute Fediverse.federated?(user),
             "the viewer must not be federated, or this proves nothing"

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert has_element?(view, "#feed-source-tabs")
      assert timeline(view) =~ "passed on by a friend"
    end
  end

  describe "switching tabs" do
    test "vutuv shows only vutuv posts, fediverse only the cached ones", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "written here on vutuv")
      account = remote_account(user, "them")
      cached_post(account, "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")

      # All: both halves.
      assert timeline(view) =~ "written here on vutuv"
      assert timeline(view) =~ "written out there"

      render_click(view, "filter-source", %{"type" => "vutuv"})
      assert timeline(view) =~ "written here on vutuv"
      refute timeline(view) =~ "written out there"
      assert has_element?(view, "[data-filter-tab='vutuv'][aria-pressed='true']")

      render_click(view, "filter-source", %{"type" => "fediverse"})
      assert timeline(view) =~ "written out there"
      refute timeline(view) =~ "written here on vutuv"

      # And back again, so a tab is never a one-way door.
      render_click(view, "filter-source", %{"type" => "all"})
      assert timeline(view) =~ "written here on vutuv"
      assert timeline(view) =~ "written out there"
    end

    test "an unknown tab value falls back to the whole feed", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "still here")
      cached_post(remote_account(user, "them"), "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")

      render_click(view, "filter-source", %{"type" => "nonsense"})

      assert timeline(view) =~ "still here"
      assert has_element?(view, "[data-filter-tab='all'][aria-pressed='true']")
    end

    test "the German render names the tabs in German", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "the only post")
      cached_post(remote_account(user, "them"), "written out there")
      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de;q=0.9")

      {:ok, _view, html} = live(conn, ~p"/feed")

      # The two proper names stay as they are; only "All" is a word.
      assert html =~ "Alle"
      assert html =~ "Fediverse"
    end

    test "an empty vutuv tab says so in German too", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      account = remote_account(user, "them")
      cached_post(account, "written out there")
      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de;q=0.9")

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert render_click(view, "filter-source", %{"type" => "vutuv"}) =~
               "Noch nichts von vutuv"
    end

    test "an empty tab says which half is missing and keeps the tabs", %{conn: conn} do
      # Reachable for the vutuv half: this member reads the fediverse but has
      # written and followed nothing here.
      {conn, user} = create_and_login_user(conn)
      cached_post(remote_account(user, "them"), "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")

      html = render_click(view, "filter-source", %{"type" => "vutuv"})

      assert html =~ "Nothing from vutuv yet"
      # Without the tabs an empty tab would be a dead end.
      assert has_element?(view, "#feed-source-tabs")
    end

    test "the tabs survive their fediverse content going away mid-session", %{conn: conn} do
      # Since the bar is gated on there BEING fediverse content, an empty
      # Fediverse tab is only reachable once the content leaves under the
      # reader — muting the account it all came from is the everyday way. The
      # bar has to stay (the assign is a fact about the mount, not the tab), or
      # they would be stranded on a tab they cannot leave.
      {conn, user} = create_and_login_user(conn)
      account = remote_account(user, "them")
      cached_post(account, "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "fediverse"})
      assert timeline(view) =~ "written out there"

      html = render_click(view, "mute-remote-account", %{"id" => account.id})

      assert html =~ "Nothing from the fediverse yet"
      assert has_element?(view, "#feed-source-tabs")
    end
  end

  describe "the tab outlives the visit (issue #1499)" do
    test "the next visit opens where the member left off", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "written here on vutuv")
      cached_post(remote_account(user, "them"), "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "fediverse"})
      assert stored_tab(user) == "fediverse"

      # A second visit: a new socket, nothing carried over but the column.
      {:ok, again, _html} = live(conn, ~p"/feed")

      assert has_element?(again, "[data-filter-tab='fediverse'][aria-pressed='true']")
      assert timeline(again) =~ "written out there"
      refute timeline(again) =~ "written here on vutuv"
    end

    test "picking All again forgets the choice", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "written here on vutuv")
      cached_post(remote_account(user, "them"), "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "vutuv"})
      render_click(view, "filter-source", %{"type" => "all"})

      assert stored_tab(user) == nil

      {:ok, again, _html} = live(conn, ~p"/feed")
      assert has_element?(again, "[data-filter-tab='all'][aria-pressed='true']")
      assert timeline(again) =~ "written out there"
    end

    test "a remembered tab whose content is gone opens on All, but is not forgotten", %{
      conn: conn
    } do
      # The stranding case: the tab bar is gated on there being fediverse
      # content at all, so opening on the remembered Fediverse tab would show
      # an empty timeline with no way back.
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "written here on vutuv")
      Posts.remember_feed_filter(user, :fediverse, :all)

      {:ok, view, _html} = live(conn, ~p"/feed")

      refute has_element?(view, "#feed-source-tabs")
      assert timeline(view) =~ "written here on vutuv"
      # Kept, so the tab comes back with the content rather than silently
      # costing them the choice.
      assert stored_tab(user) == "fediverse"
    end

    test "the pull back to All on the member's own post is not a choice", %{conn: conn} do
      # `load_source_filter/2` also runs when their own post lands on a tab
      # that cannot hold it. That is the code's doing, so it must leave the
      # remembered tab alone.
      {conn, user} = create_and_login_user(conn)
      cached_post(remote_account(user, "them"), "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "fediverse"})

      {:ok, _own} = Posts.create_post(user, %{body: "my own words"})

      assert has_element?(view, "[data-filter-tab='all'][aria-pressed='true']")
      assert stored_tab(user) == "fediverse"
    end

    test "a page computed before the tab changed is not handed to the socket", %{conn: conn} do
      # `MountHandoff` holds one entry per member, not per socket, so the tab
      # has to be part of its key: this member has a second device open, and
      # between this page's HTML and its websocket connecting they switch tabs
      # over there. Keyed only by the member, the mount below would take the
      # page computed for the tab they just left.
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "written here on vutuv")
      cached_post(remote_account(user, "them"), "written out there")

      # The document renders on All and stashes what it computed…
      conn = get(conn, ~p"/feed")
      assert html_response(conn, 200) =~ "written here on vutuv"

      # …and the tab changes before this socket connects.
      Posts.remember_feed_filter(user, :fediverse, :all)

      {:ok, view, _html} = live(conn)

      assert timeline(view) =~ "written out there"
      refute timeline(view) =~ "written here on vutuv"
    end
  end

  describe "boosts, the one source that produces both kinds" do
    test "a boosted vutuv post is a vutuv post, a boosted remote post is not", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      booster = remote_account(user, "booster")

      # A member's own post, passed on by an account out there (issue #1167).
      author = insert(:user, email_confirmed?: true)
      {:ok, local} = Posts.create_post(author, %{body: "a member post, boosted"})

      # And a cached post from a third server, passed on by the same account.
      other = remote_account(user, "third")
      remote = cached_post(other, "a remote post, boosted")

      now = DateTime.utc_now(:second)

      Repo.insert!(%PostBoost{
        remote_account_id: booster.id,
        post_id: local.id,
        activity_id: "https://social.example/activities/1",
        announced_at: now
      })

      Repo.insert!(%PostBoost{
        remote_account_id: booster.id,
        remote_post_id: remote.id,
        activity_id: "https://social.example/activities/2",
        announced_at: now
      })

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert timeline(view) =~ "a member post, boosted"
      assert timeline(view) =~ "a remote post, boosted"

      render_click(view, "filter-source", %{"type" => "vutuv"})
      assert timeline(view) =~ "a member post, boosted"
      refute timeline(view) =~ "a remote post, boosted"

      render_click(view, "filter-source", %{"type" => "fediverse"})
      assert timeline(view) =~ "a remote post, boosted"
      refute timeline(view) =~ "a member post, boosted"
    end
  end

  describe "live arrivals respect the active tab" do
    test "a followed member's new post does not fill the pill on the Fediverse tab", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {author, _post} = followed_post(user, "an older post")
      account = remote_account(user, "them")
      cached_post(account, "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "fediverse"})

      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving live"})

      refute has_element?(view, "#show-new-posts")
      refute timeline(view) =~ "arriving live"
    end

    test "the same post does fill the pill on the vutuv tab", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {author, _post} = followed_post(user, "an older post")

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "vutuv"})

      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving live"})

      assert has_element?(view, "#show-new-posts")
      render_click(view, "show-new")
      assert timeline(view) =~ "arriving live"
    end

    test "the viewer's own post pulls the feed back to All rather than vanishing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      account = remote_account(user, "them")
      cached_post(account, "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "fediverse"})

      {:ok, _own} = Posts.create_post(user, %{body: "my own words"})

      assert timeline(view) =~ "my own words"
      assert has_element?(view, "[data-filter-tab='all'][aria-pressed='true']")
    end
  end

  describe "the tab you are not on says something landed there (issue #1503)" do
    setup do
      # `record_remote_post/2` claims the shared inbound cap, which lives in the
      # RateLimiter's ETS table and outlives a test.
      Vutuv.RateLimiter.reset()
      :ok
    end

    defp dotted?(view, tab) do
      has_element?(
        view,
        "#feed-source-tabs [data-filter-tab='#{tab}'] [data-post-filter-unseen]"
      )
    end

    # A Create as the servers out there send one, from an account this member
    # already follows.
    defp remote_note(account, published \\ DateTime.utc_now(:second)) do
      unique = System.unique_integer([:positive])

      %{
        "type" => "Create",
        "actor" => account.actor_uri,
        "object" => %{
          "id" => "https://social.example/posts/#{unique}",
          "type" => "Note",
          "attributedTo" => account.actor_uri,
          "content" => "<p>frisch von drüben</p>",
          "url" => "https://social.example/@#{account.handle}/#{unique}",
          "published" => DateTime.to_iso8601(published),
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }
    end

    test "a vutuv post arriving on the Fediverse tab dots vutuv, never All", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {author, _post} = followed_post(user, "an older post")
      cached_post(remote_account(user, "them"), "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "fediverse"})

      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving live"})

      assert dotted?(view, "vutuv")
      # "All" never carries a dot, true as one would be.
      refute dotted?(view, "all")
      # You are looking at this one, so nothing on it can be unseen.
      refute dotted?(view, "fediverse")
    end

    test "landing on the tab clears its dot", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {author, _post} = followed_post(user, "an older post")
      cached_post(remote_account(user, "them"), "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "fediverse"})
      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving live"})
      assert dotted?(view, "vutuv")

      render_click(view, "filter-source", %{"type" => "vutuv"})

      assert timeline(view) =~ "arriving live"

      render_click(view, "filter-source", %{"type" => "fediverse"})
      refute dotted?(view, "vutuv")
    end

    test "a post the reader may not see dots nothing", %{conn: conn} do
      # Calibrated against the un-fixed order: `insert_entry/3` used to drop an
      # arrival on the wrong tab BEFORE asking `visible_to?/2`, which cost
      # nothing while the answer was "do nothing" and would now light a tab for
      # a post this member is turned away from.
      {conn, user} = create_and_login_user(conn)
      {author, _post} = followed_post(user, "an older post")
      cached_post(remote_account(user, "them"), "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "fediverse"})

      # Only people the author follows — and they do not follow this reader.
      {:ok, _denied} =
        Posts.create_post(author, %{
          body: "not for you",
          denials: [%{"wildcard" => "non_followees"}]
        })

      refute dotted?(view, "vutuv")
      refute dotted?(view, "all")
    end

    test "a post from another network dots the Fediverse tab", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "written here on vutuv")
      account = remote_account(user, "them")
      cached_post(account, "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "vutuv"})

      assert :ok = Fediverse.record_remote_post(remote_note(account), account.actor_uri)

      assert dotted?(view, "fediverse")
      refute dotted?(view, "all")
      refute dotted?(view, "vutuv")

      render_click(view, "filter-source", %{"type" => "fediverse"})
      assert timeline(view) =~ "frisch von drüben"
      refute dotted?(view, "fediverse")
    end

    test "a post the reader's own follow does not open dots nothing", %{conn: conn} do
      # The calibration for the probe: the nudge reaches this member (their
      # follow is not muted, so the fan-out has nothing to go on), and only
      # their own sources know that a follow nobody has answered yet does not
      # open that account's followers-only posts. Skip the probe and the dot
      # lights up here.
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "written here on vutuv")

      # An account they asked to follow and that has not answered. Its older
      # public post is readable, so the tab bar shows and the probe has a real
      # row to answer with.
      account = remote_account("private")

      Repo.insert!(%Follow{
        user_id: user.id,
        remote_account_id: account.id,
        state: "requested",
        follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/private"
      })

      old = cached_post(account, "an earlier public post")
      two_hours_ago = DateTime.add(DateTime.utc_now(:second), -7200)
      Repo.update!(Ecto.Changeset.change(old, published_at: two_hours_ago))

      # Somebody else's accepted follow is what gets the delivery recorded.
      Repo.insert!(%Follow{
        user_id: insert(:user, email_confirmed?: true).id,
        remote_account_id: account.id,
        state: "accepted",
        follow_activity_id: "https://vutuv.test/other/actor#follows/private"
      })

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "vutuv"})

      followers_only =
        put_in(remote_note(account), ["object", "to"], [account.actor_uri <> "/followers"])

      assert :ok = Fediverse.record_remote_post(followers_only, account.actor_uri)

      refute dotted?(view, "fediverse")
      refute dotted?(view, "all")
    end

    test "a muted account's post dots nothing", %{conn: conn} do
      # The reader's mute is the one per-member gate the fan-out can answer
      # itself, so this one never even leaves the write.
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "written here on vutuv")

      # One account whose old post keeps the tab bar on screen…
      old = cached_post(remote_account(user, "seen"), "read long ago")
      two_hours_ago = DateTime.add(DateTime.utc_now(:second), -7200)
      Repo.update!(Ecto.Changeset.change(old, published_at: two_hours_ago))

      # …and one this member muted.
      muted = remote_account(user, "muted")

      Repo.get_by!(Follow, remote_account_id: muted.id)
      |> Ecto.Changeset.change(muted: true)
      |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "vutuv"})

      assert :ok = Fediverse.record_remote_post(remote_note(muted), muted.actor_uri)

      refute dotted?(view, "fediverse")
      refute dotted?(view, "all")
    end

    # ── Across a page load (the dot that vanished on the way back) ──
    #
    # The dot is not state a mount inherits — every mount derives it from the
    # last moment the reader had the other tab on screen (`users.feed_source_at`,
    # `unseen_at_mount/3`). So it comes back on the next visit to /feed, and a
    # rejoin — a mount with no page load at all — takes the same path.

    # A reader whose feed has both halves, a member they follow here, and that
    # member's post — the arrival that belongs on the tab they are not on.
    defp unseen_fixture(conn) do
      {conn, user} = create_and_login_user(conn)
      {author, older} = followed_post(user, "an older post")
      # Well behind everything else: it is the tab's existing content, and a
      # test asking "is anything newer than the reader's last look" has to be
      # able to answer no.
      backdate_post!(older, 300)
      cached_post(remote_account(user, "them"), "written out there")
      {:ok, post} = Posts.create_post(author, %{body: "arriving live"})

      # Placed half a minute back: at second precision, a test whose post and
      # tab press happen inside one second decides ties rather than rules.
      {conn, user, backdate_post!(post, 30)}
    end

    # The tab this member moved to, and when.
    defp opened_on(user, filter, at) do
      Repo.update!(
        Ecto.Changeset.change(user, feed_source: to_string(filter), feed_source_at: at)
      )
    end

    defp load_feed(conn) do
      {:ok, view, _html} = live(conn, ~p"/feed")
      view
    end

    test "the next page load brings back a dot the reader never cleared", %{conn: conn} do
      {conn, user, post} = unseen_fixture(conn)

      # They moved to the Fediverse tab a second before that vutuv post landed,
      # so they have not been to the vutuv tab since it did — and a trip to
      # another page and back does not make it read.
      opened_on(user, :fediverse, NaiveDateTime.add(post.inserted_at, -1))

      assert dotted?(load_feed(conn), "vutuv")
    end

    test "the Fediverse tab is dotted the same way", %{conn: conn} do
      # The dot is not a fediverse feature and its clock is not a local one:
      # the same question is asked of whichever tab the reader is not on, so
      # this is the mirror of the test above, reader and arrival swapped.
      {conn, user} = create_and_login_user(conn)
      {_author, older} = followed_post(user, "an older post")
      backdate_post!(older, 300)

      landed = DateTime.add(DateTime.utc_now(:second), -30)

      remote =
        user
        |> remote_account("them")
        |> cached_post("written out there")
        |> Ecto.Changeset.change(published_at: landed)
        |> Repo.update!()

      at = DateTime.to_naive(remote.published_at)

      # They moved to the vutuv tab a second before that post landed out there.
      opened_on(user, :vutuv, NaiveDateTime.add(at, -1))
      assert dotted?(load_feed(conn), "fediverse")

      # And would not be dotted had they been back since.
      opened_on(user, :vutuv, NaiveDateTime.add(at, 1))
      refute dotted?(load_feed(conn), "fediverse")
    end

    test "a tab the reader has been to since stays clean", %{conn: conn} do
      {conn, user, post} = unseen_fixture(conn)

      # Moving TO the Fediverse tab after the post landed means they were
      # sitting on the vutuv one until then, so they have seen it.
      opened_on(user, :fediverse, NaiveDateTime.add(post.inserted_at, 1))

      refute dotted?(load_feed(conn), "vutuv")
    end

    test "a member whose tab clock was never stamped gets no dot", %{conn: conn} do
      # A row last written by a release that had no `feed_source_at` column:
      # nothing dates their last look, so nothing can be called unseen. It
      # heals on their first tab press.
      {conn, user, _post} = unseen_fixture(conn)
      opened_on(user, :fediverse, nil)

      refute dotted?(load_feed(conn), "vutuv")
    end

    test "pressing the tab already open does not swallow the other tab's dot", %{conn: conn} do
      {conn, user, post} = unseen_fixture(conn)
      opened_on(user, :fediverse, NaiveDateTime.add(post.inserted_at, -1))

      view = load_feed(conn)
      assert dotted?(view, "vutuv")

      # A press on the tab that is already open moves nobody: the reader has
      # still not been to the vutuv tab, so the dot must survive the press — and
      # the page load after it, which is where a clock stamped on that press
      # would quietly have swallowed it.
      render_click(view, "filter-source", %{"type" => "fediverse"})
      assert dotted?(view, "vutuv")

      assert dotted?(load_feed(conn), "vutuv")
    end

    test "the All tab is never dotted while it is the open one", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {author, _post} = followed_post(user, "an older post")
      account = remote_account(user, "them")
      cached_post(account, "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")

      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving live"})
      assert :ok = Fediverse.record_remote_post(remote_note(account), account.actor_uri)

      # "All" holds both halves, so nothing landed somewhere else.
      refute dotted?(view, "all")
      refute dotted?(view, "vutuv")
      refute dotted?(view, "fediverse")
    end
  end

  describe "a press on a slow line" do
    # Switching tabs is one round trip, and until it lands the page shows
    # exactly what it showed before: the pill only travels with the answer, so
    # on a slow connection the control reads as broken. The fix is two-part —
    # the press paints itself (CSS on LiveView's own `phx-click-loading`, see
    # `assets/css/app.css`) and the page carries less over the wire. The paint
    # is CSS and cannot be asserted here; what these tests pin is the two
    # things it silently depends on.

    # How many vutuv posts the timeline is showing (`stream_configure` ids
    # every row `feed-<entry id>`, and a member's post entry is `post-<uuid>`).
    defp rows(view), do: length(String.split(timeline(view), ~s(id="feed-post-))) - 1

    test "the tabs and the timeline sit inside one scope", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "written here on vutuv")
      cached_post(remote_account(user, "them"), "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")

      # The dimming rule is
      # `[data-filter-scope]:has([data-filter-tab].phx-click-loading)
      # [data-filter-list]`, so a refactor that moves either marker out of that
      # container kills the feedback with every other test still green.
      assert has_element?(view, "[data-filter-scope] [data-filter-tab='fediverse']")
      assert has_element?(view, "[data-filter-scope] [data-filter-list]")
    end

    test "a tab switch sends half a page, and the rest stays reachable", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {author, _post} = followed_post(user, "post 1")
      for n <- 2..12, do: {:ok, _} = Posts.create_post(author, %{body: "post #{n}"})
      cached_post(remote_account(user, "them"), "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")

      # A mount is a full page: all twelve, plus the cached remote one beside
      # them.
      assert rows(view) == 12
      assert timeline(view) =~ "written out there"

      # A tab switch is not. Twenty cards of rendered HTML is the bulk of the
      # second the member waits, and a screen holds three or four.
      render_click(view, "filter-source", %{"type" => "vutuv"})
      assert rows(view) == 10

      # Which only works because the shorter page still knows there is more —
      # `more?` comes from the same query, so the button is there and fills in
      # the rest.
      assert has_element?(view, "#load-more")
      render_click(view, "load-more")
      assert rows(view) == 12
    end
  end
end
