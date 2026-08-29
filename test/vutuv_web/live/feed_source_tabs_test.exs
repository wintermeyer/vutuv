defmodule VutuvWeb.FeedSourceTabsTest do
  @moduledoc """
  The /feed source split: vutuv and Fediverse.

  The two halves partition the timeline by what kind of post an entry carries,
  so the tests here are mostly about that split holding at its edges — the one
  source that produces both kinds (a boost, issue #1167), the live arrivals
  that never went through a query, and an installation with no fediverse at
  all.

  The tabs that used to drive it are gone; the filter band's two source
  checkboxes write the same `users.feed_source` column and hand the member back
  to the feed, which is what `switch/3` below does — the real path, without
  depending on which checkbox happens to need flipping.

  Not async: one test flips `:fediverse_enabled`, which is application env —
  process/node state the SQL sandbox does not roll back.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import VutuvWeb.FeedRailHelpers, only: [unfold: 2]
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.NoteRepost
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

  # A reply written out there under some member's post (issues #1069/#1071).
  defp remote_reply(body) do
    now = DateTime.utc_now(:second)
    unique = System.unique_integer([:positive])

    Repo.insert!(%Note{
      post_id: insert(:post, user: insert(:user, email_confirmed?: true)).id,
      object_uri: "https://social.example/n/#{unique}",
      actor_uri: "https://social.example/users/them",
      origin_url: "https://social.example/@them/#{unique}",
      handle: "them",
      display_name: "Thea Remote",
      content_text: body,
      audience: "public",
      inbox_uri: "https://social.example/users/them/inbox",
      received_at: now,
      checked_at: now,
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

  # Which halves the band is showing. vutuv has a row of its own; the fediverse
  # half has no single row any more (the flattened list makes every server a
  # peer of vutuv), so it is on when any server is — which is what the reader
  # sees and what the feed queried with.
  defp showing(view) do
    unfold(view, "sources")
    vutuv? = has_element?(view, "#filter-band-source-vutuv[checked]")
    fediverse? = has_element?(view, ~s([id^="filter-band-host-"][checked]))

    case {vutuv?, fediverse?} do
      {true, true} -> :all
      {true, false} -> :vutuv
      {false, true} -> :fediverse
      {false, false} -> :none
    end
  end

  # Switch the reader's sources the way the filter band does: write the column,
  # then hand the feed the member it was written to.
  defp switch(view, user, filter) do
    :ok = Posts.remember_feed_filter(user, filter, Repo.get!(User, user.id).feed_source)
    send(view.pid, {:filter_band, :changed, Repo.get!(User, user.id)})
    render(view)
  end

  # The stored sources, read fresh — the socket's own
  # `%User{}` was loaded at mount and knows nothing of what was written since.
  defp stored_tab(user), do: Repo.get!(User, user.id).feed_source

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

      switch(view, user, :vutuv)
      assert timeline(view) =~ "written here on vutuv"
      refute timeline(view) =~ "written out there"
      assert showing(view) == :vutuv

      switch(view, user, :fediverse)
      assert timeline(view) =~ "written out there"
      refute timeline(view) =~ "written here on vutuv"

      # And back again, so a tab is never a one-way door.
      switch(view, user, :all)
      assert timeline(view) =~ "written here on vutuv"
      assert timeline(view) =~ "written out there"
    end

    test "an unknown tab value falls back to the whole feed", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "still here")
      cached_post(remote_account(user, "them"), "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")

      switch(view, user, :nonsense)

      assert timeline(view) =~ "still here"
      assert showing(view) == :all
    end

    test "the German render names the two halves", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "the only post")
      cached_post(remote_account(user, "them"), "written out there")
      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de;q=0.9")

      {:ok, view, _html} = live(conn, ~p"/feed")
      html = view |> unfold("sources") |> render()

      # vutuv is one server among the others now, so what the German render has
      # to name is vutuv and the server the other half arrives from.
      assert html =~ "vutuv"
      assert html =~ "social.example"
      assert html =~ "QUELLEN" or html =~ "Quellen"
      # The promise the card has to make before anybody touches a switch.
      assert html =~ "stumm schalten, nicht entfolgen"
    end

    test "an empty vutuv tab says so in German too", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      account = remote_account(user, "them")
      cached_post(account, "written out there")
      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de;q=0.9")

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert switch(view, user, :vutuv) =~
               "Noch nichts von vutuv"
    end

    test "an empty tab says which half is missing and keeps the tabs", %{conn: conn} do
      # Reachable for the vutuv half: this member reads the fediverse but has
      # written and followed nothing here.
      {conn, user} = create_and_login_user(conn)
      cached_post(remote_account(user, "them"), "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")

      html = switch(view, user, :vutuv)

      assert html =~ "Nothing from vutuv yet"
      # Without the tabs an empty tab would be a dead end.
      assert view |> unfold("sources") |> has_element?(~s([id^="filter-band-host-"]))
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
      switch(view, user, :fediverse)
      assert timeline(view) =~ "written out there"

      html = render_click(view, "mute-remote-account", %{"id" => account.id})

      assert html =~ "Nothing from the fediverse yet"
      assert view |> unfold("sources") |> has_element?(~s([id^="filter-band-host-"]))
    end
  end

  describe "the tab outlives the visit (issue #1499)" do
    test "the next visit opens where the member left off", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "written here on vutuv")
      cached_post(remote_account(user, "them"), "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")
      switch(view, user, :fediverse)
      assert stored_tab(user) == "fediverse"

      # A second visit: a new socket, nothing carried over but the column.
      {:ok, again, _html} = live(conn, ~p"/feed")

      assert showing(again) == :fediverse
      assert timeline(again) =~ "written out there"
      refute timeline(again) =~ "written here on vutuv"
    end

    test "picking All again forgets the choice", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "written here on vutuv")
      cached_post(remote_account(user, "them"), "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")
      switch(view, user, :vutuv)
      switch(view, user, :all)

      assert stored_tab(user) == nil

      {:ok, again, _html} = live(conn, ~p"/feed")
      assert showing(again) == :all
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

      refute view |> unfold("sources") |> has_element?(~s([id^="filter-band-host-"]))
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
      switch(view, user, :fediverse)

      {:ok, _own} = Posts.create_post(user, %{body: "my own words"})

      assert showing(view) == :all
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

  describe "what a member here did with remote content is theirs" do
    # The reported bug: a member reshares a post from another network and it
    # shows up only under "Fediverse", which reads as vutuv having had no part
    # in it — but pressing that button *is* a vutuv act, and the reader looking
    # for what happened here looks on the vutuv tab.
    test "the viewer's own reshare of a remote post sits on the vutuv tab", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      # Something out there they follow, so the bar has both halves to show.
      cached_post(remote_account(user, "them"), "written out there")

      mine = cached_post(remote_account("stranger"), "I passed this on")
      Repo.insert!(%PostRepost{user_id: user.id, remote_post_id: mine.id})

      {:ok, view, _html} = live(conn, ~p"/feed")

      switch(view, user, :vutuv)
      assert timeline(view) =~ "I passed this on"
      refute timeline(view) =~ "written out there"

      # And it is on that tab *instead of*, not as well as, the other one.
      switch(view, user, :fediverse)
      assert timeline(view) =~ "written out there"
      refute timeline(view) =~ "I passed this on"
    end

    test "an unfederated viewer still gets a friend's reshare", %{conn: conn} do
      # Rescued from a test the rebase dropped (issue #1267, main). Its own
      # point was that a viewer the fediverse never reaches should not be shown
      # a three-tab bar over one timeline — a claim the filter band retires by
      # having no bar to hide, so `refute has_element?("#feed-source-tabs")`
      # would now pass whatever the feed did.
      #
      # What does not retire with it is the content claim underneath, and it is
      # the sharper of the two: this reader follows nobody out there and has no
      # actor, so everything from another network reaches them only because a
      # member they follow *here* passed it on. The federation guard is what
      # makes that true rather than assumed.
      {conn, user} = create_and_login_user(conn)
      sharer = insert(:user, email_confirmed?: true)
      Social.follow(user, sharer.id)

      post = cached_post(remote_account("stranger"), "passed on by a friend")
      Repo.insert!(%PostRepost{user_id: sharer.id, remote_post_id: post.id})

      refute Fediverse.federated?(user),
             "the viewer must not be federated, or this proves nothing"

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert timeline(view) =~ "passed on by a friend"
    end

    test "somebody else's reshare is a vutuv act too", %{conn: conn} do
      # The reader did not press the button, but a member here did — and that is
      # what the tab is about. "Fediverse" is what arrives without anybody here
      # doing anything; filing a friend's reshare there sent the reader looking
      # for their own network's activity under the other network's name.
      {conn, user} = create_and_login_user(conn)
      sharer = insert(:user, email_confirmed?: true)
      Social.follow(user, sharer.id)

      # Something the reader follows out there, so the bar has both halves.
      cached_post(remote_account(user, "them"), "written out there")

      post = cached_post(remote_account("stranger"), "passed on by a friend")
      Repo.insert!(%PostRepost{user_id: sharer.id, remote_post_id: post.id})

      {:ok, view, _html} = live(conn, ~p"/feed")

      switch(view, user, :vutuv)
      assert timeline(view) =~ "passed on by a friend"

      switch(view, user, :fediverse)
      refute timeline(view) =~ "passed on by a friend"
      assert timeline(view) =~ "written out there"
    end

    test "the same holds for a reply the viewer passed on", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      cached_post(remote_account(user, "them"), "written out there")

      note = remote_reply("I passed this reply on")
      Repo.insert!(%NoteRepost{user_id: user.id, note_id: note.id})

      {:ok, view, _html} = live(conn, ~p"/feed")

      switch(view, user, :vutuv)
      assert timeline(view) =~ "I passed this reply on"

      switch(view, user, :fediverse)
      refute timeline(view) =~ "I passed this reply on"
    end

    test "an own reshare alone leaves the Fediverse tab empty, so no bar", %{conn: conn} do
      # Nothing reaches this member from out there except what they carried in
      # themselves — so "Fediverse" can never fill, and three tabs over one
      # timeline is exactly what issue #1267 took away.
      {conn, user} = create_and_login_user(conn)

      mine = cached_post(remote_account("stranger"), "I passed this on")
      Repo.insert!(%PostRepost{user_id: user.id, remote_post_id: mine.id})

      {:ok, view, _html} = live(conn, ~p"/feed")

      refute view |> unfold("sources") |> has_element?(~s([id^="filter-band-host-"]))
      assert timeline(view) =~ "I passed this on"
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

      switch(view, user, :vutuv)
      assert timeline(view) =~ "a member post, boosted"
      refute timeline(view) =~ "a remote post, boosted"

      switch(view, user, :fediverse)
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
      switch(view, user, :fediverse)

      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving live"})

      refute has_element?(view, "#show-new-posts")
      refute timeline(view) =~ "arriving live"
    end

    test "the same post does fill the pill on the vutuv tab", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {author, _post} = followed_post(user, "an older post")

      {:ok, view, _html} = live(conn, ~p"/feed")
      switch(view, user, :vutuv)

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
      switch(view, user, :fediverse)

      {:ok, _own} = Posts.create_post(user, %{body: "my own words"})

      assert timeline(view) =~ "my own words"
      assert showing(view) == :all
    end
  end

  describe "a source switch on a slow line" do
    # Switching sources is one round trip, and until it lands the page shows
    # exactly what it showed before. The page carries less over the wire for
    # that reason, which is what this pins.

    # How many vutuv posts the timeline is showing (`stream_configure` ids
    # every row `feed-<entry id>`, and a member's post entry is `post-<uuid>`).
    defp rows(view), do: length(String.split(timeline(view), ~s(id="feed-post-))) - 1

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

      # A source switch is not. Twenty cards of rendered HTML is the bulk of the
      # second the member waits, and a screen holds three or four.
      switch(view, user, :vutuv)
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
