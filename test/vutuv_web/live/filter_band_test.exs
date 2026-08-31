defmodule VutuvWeb.PostLive.FilterBandTest do
  @moduledoc """
  The feed's filter band, end to end through the LiveView: what it lists, and
  that each switch lands in the table the feed actually reads.

  Every assertion here goes through the rendered page rather than the context
  functions, because the band's whole reason for existing is that the switches
  were already there and nobody could find them. A test that called
  `Social.set_follow_mute/3` directly would pass with the panel unwired.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import VutuvWeb.FeedRailHelpers, only: [unfold: 2]

  alias Vutuv.ContentFilters
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Posts
  alias Vutuv.Social.Follow

  defp remote_account(host, handle) do
    actor = "https://#{host}/users/#{handle}"

    Repo.insert!(%RemoteAccount{
      actor_uri: actor,
      host: host,
      handle: "@#{handle}@#{host}",
      name: handle,
      inbox_uri: actor <> "/inbox"
    })
  end

  defp remote_follow(user, account) do
    Repo.insert!(%Fediverse.Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      muted: false,
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{account.id}"
    })
  end

  defp with_friend(conn) do
    {conn, user} = create_and_login_user(conn)
    friend = insert(:activated_user, first_name: "Lena", last_name: "Loud")
    insert(:follow, follower: user, followee: friend)

    %{conn: conn, user: user, friend: friend}
  end

  defp local_muted?(user, followee) do
    Repo.get_by!(Follow, follower_id: user.id, followee_id: followee.id).muted
  end

  defp muted_remote?(user, account) do
    Repo.get_by!(Fediverse.Follow, user_id: user.id, remote_account_id: account.id).muted
  end

  # A source starts folded, so its accounts are not in the DOM until the reader
  # opens it — which is what they do, and what a test has to.
  defp twist(view, key) do
    view
    |> element(~s(#filter-band button[phx-click="twist"][phx-value-key="#{key}"]))
    |> render_click()

    view
  end

  describe "the account branch" do
    test "lists a followed account with what it posted", %{conn: conn} do
      %{conn: conn, friend: friend} = with_friend(conn)
      {:ok, _} = Posts.create_post(friend, %{body: "loud and clear"})

      {:ok, view, _html} = live(conn, ~p"/feed")
      html = view |> unfold("sources") |> twist("vutuv") |> render()

      assert html =~ ~s(id="filter-band")
      assert html =~ "Lena Loud"
      assert html =~ "filter-band-account-user:#{friend.id}"
    end

    test "switching an account off mutes the follow and keeps the row", %{conn: conn} do
      %{conn: conn, user: user, friend: friend} = with_friend(conn)
      {:ok, _} = Posts.create_post(friend, %{body: "loud and clear"})

      {:ok, view, _html} = live(conn, ~p"/feed")
      view |> unfold("sources") |> twist("vutuv")

      html =
        view
        |> element(~s(#filter-band-account-user\\:#{friend.id}))
        |> render_click()

      assert Repo.get_by!(Follow, follower_id: user.id, followee_id: friend.id).muted
      # The row survives its own mute — it is the only way back.
      assert html =~ "filter-band-account-user:#{friend.id}"

      view |> element(~s(#filter-band-account-user\\:#{friend.id})) |> render_click()
      refute Repo.get_by!(Follow, follower_id: user.id, followee_id: friend.id).muted
    end

    test "the search narrows the branch", %{conn: conn} do
      %{conn: conn, user: user} = with_friend(conn)
      other = insert(:activated_user, first_name: "Nina", last_name: "Quiet")
      insert(:follow, follower: user, followee: other)

      {:ok, view, _html} = live(conn, ~p"/feed")
      assert view |> unfold("sources") |> twist("vutuv") |> render() =~ "Nina Quiet"

      html =
        view
        |> element(~s(#filter-band form[phx-change="search"]))
        |> render_change(%{"query" => "lena"})

      assert html =~ "Lena Loud"
      refute html =~ "Nina Quiet"
    end
  end

  describe "an open card and the arriving page" do
    # Why the dead render owes no list is written at `FilterBand.load/1`.
    # Calibrated against the un-deferred code: there the dead render carries
    # the search field and no skeleton, and both assertions go red.
    test "the dead render shows a skeleton, the connected mount the list", %{conn: conn} do
      %{conn: conn, user: user} = with_friend(conn)

      {:ok, _} =
        Posts.save_feed_rail(user, %{order: ["sources"], collapsed: [], removed: []})

      conn = get(conn, ~p"/feed")
      dead_html = html_response(conn, 200)

      assert elements(dead_html, "#filter-band-skeleton") != []
      assert elements(dead_html, ~s(#filter-band form[phx-change="search"])) == []

      {:ok, _view, html} = live(conn)
      assert elements(html, "#filter-band-skeleton") == []
      assert elements(html, ~s(#filter-band form[phx-change="search"])) != []
    end

    test "the folded default gets no skeleton", %{conn: conn} do
      %{conn: conn} = with_friend(conn)

      dead_html = conn |> get(~p"/feed") |> html_response(200)

      assert elements(dead_html, "#filter-band-skeleton") == []
    end

    # A feed re-render the band's data does not depend on — "Load more"
    # replaces `entries` — must not re-run the card's ~8 queries. Calibrated
    # against the ungated code: there the load-more click re-runs
    # `FeedBand.accounts/2` and the message arrives.
    test "a load-more does not re-run the card's queries", %{conn: conn} do
      %{conn: conn, user: user, friend: friend} = with_friend(conn)
      {:ok, _} = Posts.save_feed_rail(user, %{order: ["sources"], collapsed: [], removed: []})
      for n <- 1..41, do: {:ok, _} = Posts.create_post(friend, %{body: "Beitrag #{n}"})

      {:ok, view, _html} = live(conn, ~p"/feed")
      assert has_element?(view, "#load-more")

      test_pid = self()
      lv_pid = view.pid
      handler_id = "band-gate-#{inspect(self())}"

      :telemetry.attach(
        handler_id,
        [:vutuv, :repo, :query],
        fn _e, _m, md, _c ->
          if self() == lv_pid and
               String.contains?(md.query, ~s(FROM "follows" AS f0 INNER JOIN "users")) do
            send(test_pid, :band_reloaded)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      view |> element("#load-more") |> render_click()
      refute_received :band_reloaded
    end

    # The one live path that changes follow state from OUTSIDE the card — the
    # remote card menu's mute — must still reach it, or the account keeps its
    # tick over a mute that already stands. Calibrated by dropping the
    # `bump_band_refresh/1` on the feed's handler: the row then stays checked.
    test "a remote mute from a card menu still refreshes the card", %{conn: conn} do
      %{conn: conn, user: user} = with_friend(conn)
      {:ok, _} = Posts.save_feed_rail(user, %{order: ["sources"], collapsed: [], removed: []})
      account = remote_account("social.example", "them")
      remote_follow(user, account)

      {:ok, view, _html} = live(conn, ~p"/feed")
      view |> twist("social.example") |> render()

      row = ~s(#filter-band-account-remote\\:#{account.id})
      assert has_element?(view, row <> "[checked]")

      render_click(view, "mute-remote-account", %{"id" => account.id})

      assert has_element?(view, row)
      refute has_element?(view, row <> "[checked]")
    end
  end

  describe "what is waiting" do
    test "the rail card and the pill both quote the waiting post", %{conn: conn} do
      %{conn: conn, friend: friend} = with_friend(conn)

      {:ok, live, html} = live(conn, ~p"/feed")
      refute html =~ ~s(id="unread-posts")

      {:ok, post} = Posts.create_post(friend, %{body: "Sturmflutwarnung für die Wesermündung"})

      html = render(live)

      # The card lists it, the pill quotes the newest one, and the timeline has
      # not moved: all three at once is the whole point of the arrangement.
      #
      # Both name assertions are scoped to the card. Unscoped, "who wrote it"
      # was satisfied by the account list in "Sources" further down
      # the rail, which happens to name the same person — so the test passed
      # without the card quoting anybody at all, and said "Lena Loud" where the
      # card really writes the handle.
      assert html =~ ~s(id="unread-posts")
      assert has_element?(live, "#unread-posts", "Sturmflutwarnung für die Wesermündung")
      assert has_element?(live, "#unread-posts", "@#{friend.username}")
      # The row is drawn already — carrying `hidden`, which is what keeps the
      # timeline still and makes the press cost no round trip.
      assert has_element?(live, "#feed-posts [hidden][id*='#{post.id}']")

      live |> element("#unread-insert") |> render_click()

      assert has_element?(live, "#feed-posts [id*='#{post.id}']")
      refute render(live) =~ ~s(id="unread-posts")
    end
  end

  # The vutuv half put its accounts straight on the page while the fediverse
  # half stopped at its servers and hid the accounts behind a small grey
  # triangle: the same question answered at two different depths, and only one
  # of them findable (Stefan, 2026-08-28). Calibrated by seeding `closed` with
  # the host again — the account row then never renders.
  describe "the fediverse branch" do
    test "lists a server's accounts without being asked", %{conn: conn} do
      %{conn: conn, user: user} = with_friend(conn)
      account = remote_account("social.example", "them")
      remote_follow(user, account)

      {:ok, view, _html} = live(conn, ~p"/feed")
      html = view |> unfold("sources") |> render()

      # The server is on the page; its accounts arrive when it is opened, which
      # is the whole point of the density this variant offers.
      assert html =~ "social.example"
      refute html =~ "filter-band-account-remote:#{account.id}"

      assert view |> twist("social.example") |> render() =~
               "filter-band-account-remote:#{account.id}"
    end

    # One field, both halves. A reader looking somebody up does not know which
    # half they live on — a person here today is an account out there tomorrow —
    # so a search box per branch would make them guess, and a wrong guess
    # answers "nothing found". Calibrated by dropping `query:` from the
    # `FeedBand.servers/2` call: the remote account then survives every search.
    test "one search narrows the vutuv accounts and the servers alike", %{conn: conn} do
      %{conn: conn, user: user} = with_friend(conn)
      other = insert(:activated_user, first_name: "Nina", last_name: "Quiet")
      insert(:follow, follower: user, followee: other)

      account = remote_account("social.example", "them")
      remote_follow(user, account)

      {:ok, view, _html} = live(conn, ~p"/feed")
      unfold(view, "sources")

      # A name only the remote side has: the vutuv half empties, the server
      # stays with the account that matched.
      html =
        view
        |> element(~s(#filter-band form[phx-change="search"]))
        |> render_change(%{"query" => "them"})

      assert html =~ "social.example"
      assert html =~ "filter-band-account-remote:#{account.id}"
      refute html =~ "Nina Quiet"

      # And the other way round, without the reader saying where to look.
      html =
        view
        |> element(~s(#filter-band form[phx-change="search"]))
        |> render_change(%{"query" => "nina"})

      assert html =~ "Nina Quiet"
      refute html =~ "social.example"

      # A server matched by its own host keeps all of its accounts.
      html =
        view
        |> element(~s(#filter-band form[phx-change="search"]))
        |> render_change(%{"query" => "social.example"})

      assert html =~ "filter-band-account-remote:#{account.id}"
    end

    test "a search that matches nothing says so once, not twice", %{conn: conn} do
      %{conn: conn, user: user} = with_friend(conn)
      remote_follow(user, remote_account("social.example", "them"))

      {:ok, view, _html} = live(conn, ~p"/feed")
      unfold(view, "sources")

      html =
        view
        |> element(~s(#filter-band form[phx-change="search"]))
        |> render_change(%{"query" => "zzzznothing"})

      assert html =~ "Nothing found"
      refute html =~ "social.example"
    end

    # Kayak's "only": one press for what would otherwise be one press per
    # source. It writes the same two columns the checkboxes write, which is why
    # "Select all" is a way back rather than a special case — and why it lives
    # on source rows alone: an account's "only" would have to mute every other
    # follow, thousands of rows for the vutuv side, erasing the handful of
    # people the member had deliberately silenced.
    test "only leaves one source on, and select-all brings them back", %{conn: conn} do
      %{conn: conn, user: user, friend: friend} = with_friend(conn)
      {:ok, post} = Posts.create_post(friend, %{body: "written here on vutuv"})
      remote_follow(user, remote_account("social.example", "them"))

      {:ok, view, _html} = live(conn, ~p"/feed")
      unfold(view, "sources")

      # Only that server: vutuv goes off, every other host is muted.
      view
      |> element(~s(#filter-band button[phx-click="only"][phx-value-host="social.example"]))
      |> render_click()

      assert Repo.reload!(user).feed_source == "fediverse"
      assert Vutuv.Fediverse.muted_hosts(Repo.reload!(user)) == []
      refute has_element?(view, "#feed-posts [id*='#{post.id}']")

      # Only vutuv: the mirror image, and the replacement for the "Fediverse"
      # node the flattened list no longer has.
      view
      |> element(~s(#filter-band button[phx-click="only"][phx-value-host="vutuv"]))
      |> render_click()

      assert Repo.reload!(user).feed_source == nil
      assert Vutuv.Fediverse.muted_hosts(Repo.reload!(user)) == ["social.example"]
      assert has_element?(view, "#feed-posts [id*='#{post.id}']")

      view
      |> element(~s(#filter-band button[phx-click="all-servers"]))
      |> render_click()

      assert Repo.reload!(user).feed_source == nil
      assert Vutuv.Fediverse.muted_hosts(Repo.reload!(user)) == []
    end

    # The same shortcut one level down, which is what Stefan asked for on
    # 2026-08-28. It costs more than the source one: a source's "off" is a short
    # array on the member's own row, an account's "off" is a row per follow, so
    # this is the first control in the card that writes over a considered
    # choice. That is why it arrives with an undo, and why "Select all" had to
    # learn to unmute accounts too — without that there is no way back from
    # "only this account" except one press per follow.
    test "only on a remote account silences its neighbours on the same server",
         %{conn: conn} do
      %{conn: conn, user: user, friend: friend} = with_friend(conn)
      {:ok, post} = Posts.create_post(friend, %{body: "written here on vutuv"})
      keep = remote_account("social.example", "keep")
      drop = remote_account("social.example", "drop")
      elsewhere = remote_account("other.example", "elsewhere")
      Enum.each([keep, drop, elsewhere], &remote_follow(user, &1))

      {:ok, view, _html} = live(conn, ~p"/feed")
      unfold(view, "sources")
      twist(view, "social.example")

      view
      |> element(~s(#filter-band button[phx-click="only"][phx-value-key="remote:#{keep.id}"]))
      |> render_click()

      # Its own server stays on and every other one goes off, so a whole host
      # costs one array entry rather than a mute per account behind it.
      assert Repo.reload!(user).feed_source == "fediverse"
      assert Fediverse.muted_hosts(Repo.reload!(user)) == ["other.example"]
      refute has_element?(view, "#feed-posts [id*='#{post.id}']")

      # Only the neighbours it actually shares a server with are muted. The
      # account on the other host is not, because its host already is: muting
      # it as well would outlive the reader switching that host back on, and
      # then the card would show a ticked server delivering nothing.
      assert muted_remote?(user, drop)
      refute muted_remote?(user, keep)
      refute muted_remote?(user, elsewhere)
    end

    test "only on a vutuv account silences the other people you follow", %{conn: conn} do
      %{conn: conn, user: user, friend: friend} = with_friend(conn)
      other = insert(:activated_user, first_name: "Otto", last_name: "Other")
      insert(:follow, follower: user, followee: other)
      remote_follow(user, remote_account("social.example", "them"))

      {:ok, view, _html} = live(conn, ~p"/feed")
      unfold(view, "sources")
      twist(view, "vutuv")

      view
      |> element(~s(#filter-band button[phx-click="only"][phx-value-key="user:#{friend.id}"]))
      |> render_click()

      assert Repo.reload!(user).feed_source == nil
      assert Fediverse.muted_hosts(Repo.reload!(user)) == ["social.example"]
      refute local_muted?(user, friend)
      assert local_muted?(user, other)
    end

    # Calibrated by dropping the capture in `remember/1`: the undo button then
    # renders, restores the hosts, and hands the deliberate mute back unmuted —
    # which is the whole failure this exists to prevent, and it is silent.
    test "undo puts the previous state back, a deliberate mute included",
         %{conn: conn} do
      %{conn: conn, user: user, friend: friend} = with_friend(conn)
      silenced = insert(:activated_user, first_name: "Sina", last_name: "Silent")
      insert(:follow, follower: user, followee: silenced, muted: true)
      remote_follow(user, remote_account("social.example", "them"))

      {:ok, view, _html} = live(conn, ~p"/feed")
      unfold(view, "sources")
      twist(view, "vutuv")

      view
      |> element(~s(#filter-band button[phx-click="only"][phx-value-key="user:#{friend.id}"]))
      |> render_click()

      assert local_muted?(user, silenced)
      assert Fediverse.muted_hosts(Repo.reload!(user)) == ["social.example"]

      view |> element(~s(#filter-band button[phx-click="undo"])) |> render_click()

      # Exactly the state before the press, not "everything on": the member had
      # silenced Sina by hand and the bulk act must not quietly hand her back.
      assert local_muted?(user, silenced)
      refute local_muted?(user, friend)
      assert Fediverse.muted_hosts(Repo.reload!(user)) == []
      refute has_element?(view, ~s(#filter-band button[phx-click="undo"]))
    end

    # The other half of the bargain. Before account mutes could be written in
    # bulk, "Select all" had only two columns to clear and left the follows
    # alone; now it is the standing way back from an account's "only".
    test "select-all now unmutes the accounts too", %{conn: conn} do
      %{conn: conn, user: user, friend: friend} = with_friend(conn)
      other = insert(:activated_user, first_name: "Otto", last_name: "Other")
      insert(:follow, follower: user, followee: other)
      account = remote_account("social.example", "them")
      remote_follow(user, account)

      {:ok, view, _html} = live(conn, ~p"/feed")
      unfold(view, "sources")
      twist(view, "vutuv")

      # A vutuv account is the case that really leaves account mutes behind: it
      # silences every other local follow. Pressing "only" on a lone remote
      # account writes no account mute at all (it has no neighbours on its
      # server), so a test built on that one stays green with the restore
      # removed and proves nothing.
      view
      |> element(~s(#filter-band button[phx-click="only"][phx-value-key="user:#{friend.id}"]))
      |> render_click()

      assert local_muted?(user, other)

      view |> element(~s(#filter-band button[phx-click="all-servers"])) |> render_click()

      refute local_muted?(user, other)
      refute local_muted?(user, friend)
      refute muted_remote?(user, account)
      assert Fediverse.muted_hosts(Repo.reload!(user)) == []
      assert Repo.reload!(user).feed_source == nil
    end

    # Found in the browser, not in a test: pressing "only" on one of
    # @wintermeyer's 2,664 follows rendered 2,678 unticked rows into a rail
    # card the width of a phone. The rule that a muted account survives the cap
    # was written when a muted account was a handful of considered choices; a
    # bulk switch makes it every follow the member has, and an unbounded tail
    # then turns the list into the thing the cap exists to prevent.
    #
    # Calibrated by taking the `limit:` back out of `muted_accounts/2`: the
    # count goes to one row per follow.
    test "a bulk mute cannot grow the card past its own cap", %{conn: conn} do
      %{conn: conn, user: user} = with_friend(conn)

      for _ <- 1..20 do
        insert(:follow, follower: user, followee: insert(:activated_user))
      end

      {:ok, view, _html} = live(conn, ~p"/feed")
      unfold(view, "sources")
      twist(view, "vutuv")

      # Whichever account the card is actually showing, not one this test picked
      # out: with every follow at zero posts the order among them is the query's
      # to decide, and an earlier version of this test pressed a button that was
      # below the cap on two seeds out of six.
      [_, key] = Regex.run(~r/phx-value-key="(user:[0-9a-f-]+)"/, render(view))

      view
      |> element(~s(#filter-band button[phx-click="only"][phx-value-key="#{key}"]))
      |> render_click()

      rows =
        view
        |> render()
        |> then(&Regex.scan(~r/id="filter-band-account-user:/, &1))
        |> length()

      # Six shown plus at most six carried past the cap. Without the bound the
      # tail is one row per muted follow, so this reads 21.
      assert rows <= 12, "the card listed #{rows} accounts, so the cap is not holding"

      # And the way back is above the list, not in it: search, select-all, undo.
      assert has_element?(view, ~s(#filter-band button[phx-click="all-servers"]))
      assert has_element?(view, ~s(#filter-band button[phx-click="undo"]))
    end

    test "the twist folds the accounts away and back", %{conn: conn} do
      %{conn: conn, user: user} = with_friend(conn)
      account = remote_account("social.example", "them")
      remote_follow(user, account)

      {:ok, view, _html} = live(conn, ~p"/feed")
      unfold(view, "sources")

      assert view |> twist("social.example") |> render() =~
               "filter-band-account-remote:#{account.id}"

      refute view |> twist("social.example") |> render() =~
               "filter-band-account-remote:#{account.id}"
    end
  end

  describe "words and tags" do
    test "a word rule is written to the member's own deny list", %{conn: conn} do
      %{conn: conn, user: user} = with_friend(conn)

      {:ok, view, _html} = live(conn, ~p"/feed")

      view
      |> element(~s(#filter-band-words form))
      |> render_submit(%{"pattern" => "Kryptowährung"})

      # `whole_word: false` is the card's deliberate default: German compounds
      # mean a member typing "Zeugnis" wants "Arbeitszeugnis" caught too, and
      # the live preview is what keeps a permissive rule honest. The bare word
      # is still available, on /settings/filters.
      assert [%{kind: :keyword, pattern: "Kryptowährung", whole_word: false}] =
               ContentFilters.list_for_user(user)
    end

    # The whole reason the default flipped, and the case a whole-word rule
    # silently misses. Calibrated by putting `whole_word: true` back: the post
    # then stays in the feed and nothing about the card says why.
    test "a word rule reaches inside a longer word", %{conn: conn} do
      %{conn: conn, friend: friend} = with_friend(conn)
      {:ok, _} = Posts.create_post(friend, %{body: "Die Zeugnisanalyse läuft gut."})

      {:ok, view, _html} = live(conn, ~p"/feed")

      view
      |> element(~s(#filter-band-words form))
      |> render_submit(%{"pattern" => "Zeugnis"})

      refute render(view) =~ "Die Zeugnisanalyse läuft gut."
      assert has_element?(view, "#feed-posts [data-filtered-post]")
    end

    test "a tag in the feed is offered, and pressing it hides that tag", %{conn: conn} do
      %{conn: conn, user: user, friend: friend} = with_friend(conn)
      tag = insert(:tag, name: "Zeugnisanalyse")
      {:ok, post} = Posts.create_post(friend, %{body: "with a tag on it"})
      Repo.insert!(%Vutuv.Posts.PostTag{post_id: post.id, tag_id: tag.id})

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert view |> unfold("hidden_tags") |> render() =~ "Zeugnisanalyse"

      view
      |> element(~s(#filter-band-tags button[phx-value-pattern="Zeugnisanalyse"]))
      |> render_click()

      assert [%{kind: :tag, pattern: "Zeugnisanalyse"}] = ContentFilters.list_for_user(user)
    end

    test "the preview counts what the rule would fold and quotes it", %{conn: conn} do
      %{conn: conn, friend: friend} = with_friend(conn)
      {:ok, _} = Posts.create_post(friend, %{body: "Bitcoin steht wieder unter Druck"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      html =
        view
        |> element(~s(#filter-band-words form))
        |> render_change(%{"pattern" => "Bitcoin"})

      assert html =~ "1"
      refute html =~ "Ganze Wörter"

      # A count answers "is this rule too wide"; it cannot answer "is it the
      # right rule". So the hits are named: who wrote each and how it opens.
      assert has_element?(view, "#filter-band-words-hits", "Bitcoin steht wieder unter Druck")
      assert has_element?(view, "#filter-band-words-hits", "@#{friend.username}")
    end

    # The row a post arrives on is a conversation, and a match is regularly an
    # ancestor rather than the post the row is keyed on. Quoting the row would
    # then name the wrong author and the wrong sentence — which is exactly what
    # a reader is looking at the preview to check. Calibrated by quoting
    # `PostTeaser.record(entry)` instead: the preview then reads the viewer's
    # own reply.
    test "the quote is the post that matched, not the row it arrived on", %{conn: conn} do
      %{conn: conn, user: user, friend: friend} = with_friend(conn)

      {:ok, parent} = Posts.create_post(friend, %{body: "Bitcoin steht wieder unter Druck"})
      {:ok, _} = Posts.create_reply(user, parent, %{body: "Sehe ich genauso."})

      {:ok, view, _html} = live(conn, ~p"/feed")

      view
      |> element(~s(#filter-band-words form))
      |> render_change(%{"pattern" => "Bitcoin"})

      assert has_element?(view, "#filter-band-words-hits", "Bitcoin steht wieder unter Druck")
      assert has_element?(view, "#filter-band-words-hits", "@#{friend.username}")
      refute has_element?(view, "#filter-band-words-hits", "Sehe ich genauso.")
    end

    test "a post the reader wrote themselves is never quoted as a hit", %{conn: conn} do
      %{conn: conn, user: user} = with_friend(conn)
      {:ok, _} = Posts.create_post(user, %{body: "Bitcoin steht wieder unter Druck"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      html =
        view
        |> element(~s(#filter-band-words form))
        |> render_change(%{"pattern" => "Bitcoin"})

      # The filter leaves the reader's own posts alone, so a preview promising
      # to fold one would be a promise the feed then breaks.
      assert html =~ "Matches nothing in your feed right now"
      refute has_element?(view, "#filter-band-words-hits")
    end
  end
end
