defmodule VutuvWeb.FeedRemotePostsTest do
  @moduledoc """
  A followed account's post in the home feed (issue #1161): the remote card, the
  content-filter placeholder over it, and the report control that deletes our
  copy.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost

  @actor "https://social.example/users/them"

  defp cached_post(user, overrides \\ %{}) do
    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: @actor,
        host: "social.example",
        handle: "them",
        name: "Them Themself",
        inbox_uri: @actor <> "/inbox"
      })

    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/1"
    })

    now = DateTime.utc_now(:second)

    Repo.insert!(
      struct(
        %RemotePost{
          remote_account_id: account.id,
          object_uri: "https://social.example/posts/1",
          origin_url: "https://social.example/@them/1",
          content_text: "A thought from over there.",
          audience: "public",
          kind: "note",
          published_at: now,
          received_at: now,
          expires_at: DateTime.add(now, 86_400)
        },
        overrides
      )
    )
  end

  test "a followed account's post renders with the remote skin and no action bar", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    post = cached_post(user)

    {:ok, view, html} = live(conn, ~p"/feed")

    assert has_element?(view, "[data-remote-post='#{post.id}']")
    assert html =~ "A thought from over there."
    assert html =~ "@them@social.example"
    # It links out to where it really lives, and offers one heart but no vutuv
    # action bar — replying and resharing are #1165/#1166.
    assert has_element?(view, "[data-remote-origin][href='https://social.example/@them/1']")
    refute has_element?(view, "[data-remote-post='#{post.id}'] [data-post-actions]")
  end

  test "the body reads like a normal post, not a quotation", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    post = cached_post(user)

    {:ok, view, _html} = live(conn, ~p"/feed")

    # The origin is carried by the globe badge, the host chip and the footer
    # line; the text itself is not set apart behind a dashed quote rail
    # (removed 2026-07-30 — it read as an unexplained decoration).
    assert has_element?(view, "[data-remote-post='#{post.id}'] .markdown")
    refute has_element?(view, "[data-remote-post='#{post.id}'] .border-dashed")
  end

  test "the body is formatted: links are clickable, hashtags reach our tag pages", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    # The hashtag grammar is `[A-Za-z0-9_]+`, so the factory's hyphenated name
    # would not parse; and a tag page only links once it lists somebody.
    name = "klima#{System.unique_integer([:positive])}"
    {:ok, user_tag} = Vutuv.Tags.add_user_tag(user, name)
    tag = Repo.preload(user_tag, :tag).tag

    cached_post(user, %{
      content_text: "Read this: https://taz.de/Klimaschutzvorgaben/!6199402/ ##{name}"
    })

    {:ok, _view, html} = live(conn, ~p"/feed")

    assert html =~ ~s(href="https://taz.de/Klimaschutzvorgaben/!6199402/")
    assert html =~ ~s(href="/tags/#{tag.slug}")
  end

  describe "the heart (issue #1164)" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      user = user |> Ecto.Changeset.change(fediverse_followers?: true) |> Repo.update!()
      {:ok, _actor} = Fediverse.ensure_actor(user)

      %{conn: conn, user: Repo.reload!(user), post: cached_post(user)}
    end

    test "paints the reader's own state with no reload and no count", ctx do
      {:ok, view, html} = live(ctx.conn, ~p"/feed")

      # Nothing about how many others liked it: the real number is on their
      # server, and one assembled from what passed through here would be a lie.
      assert has_element?(view, "[data-remote-act='like']")
      refute html =~ "data-on=\"on\""

      view |> element("[data-remote-act='like']") |> render_click()

      assert has_element?(view, "[data-remote-act='like'][data-on='on']")
      assert has_element?(view, "[data-remote-act='like']")

      view |> element("[data-remote-act='like']") |> render_click()

      refute has_element?(view, "[data-remote-act='like'][data-on='on']")
    end

    test "resharing paints the state and says so, and takes it back", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/feed")

      html = view |> element("[data-remote-act='repost']") |> render_click()

      assert has_element?(view, "[data-remote-act='repost'][data-on='on']")
      # Publishing, unlike the heart: the reader's own feed does not show their
      # reshare back to them, so a silent button would leave them unsure.
      assert html =~ "Repostet" or html =~ "Reposted"

      view |> element("[data-remote-act='repost']") |> render_click()

      refute has_element?(view, "[data-remote-act='repost'][data-on='on']")
    end

    test "a post reaching the reader twice renders one card", ctx do
      # The reader follows the author (source 4) and a member who reshared the
      # same post (source 5). One cached row, one card.
      sharer = insert(:activated_user, fediverse_followers?: true)
      {:ok, _} = Vutuv.Fediverse.ensure_actor(sharer)
      Vutuv.Social.follow(ctx.user, sharer.id)
      {:ok, :reposted} = Vutuv.Fediverse.repost_remote_post(Repo.reload!(sharer), ctx.post)

      {:ok, view, _html} = live(ctx.conn, ~p"/feed")

      cards =
        render(view)
        |> String.split("data-remote-post=\"#{ctx.post.id}\"")
        |> length()
        |> Kernel.-(1)

      assert cards == 1
    end

    test "a frozen member's reshares reach nobody", ctx do
      sharer = insert(:activated_user, fediverse_followers?: true)
      {:ok, _} = Vutuv.Fediverse.ensure_actor(sharer)
      Vutuv.Social.follow(ctx.user, sharer.id)
      {:ok, :reposted} = Vutuv.Fediverse.repost_remote_post(Repo.reload!(sharer), ctx.post)

      # Carrying a third party's post into other people's feeds is exactly what
      # an account with an open case must not keep doing.
      sharer
      |> Ecto.Changeset.change(frozen_at: NaiveDateTime.utc_now(:second))
      |> Repo.update!()

      Repo.delete_all(Vutuv.Fediverse.Follow)

      {:ok, view, _html} = live(ctx.conn, ~p"/feed")

      refute has_element?(view, "[data-remote-post='#{ctx.post.id}']")
    end

    test "a followers-only post offers no reshare at all", ctx do
      Repo.update_all(Vutuv.Fediverse.RemotePost, set: [audience: "followers"])

      {:ok, view, _html} = live(ctx.conn, ~p"/feed")

      # No control rather than one that refuses: passing on an audience its
      # author narrowed is not ours to do.
      assert has_element?(view, "[data-remote-post='#{ctx.post.id}']")
      refute has_element?(view, "[data-remote-act='repost']")
      # The heart stays: liking is private and reaches nobody new.
      assert has_element?(view, "[data-remote-act='like']")
    end

    test "a member who does not federate is told where the switch is", ctx do
      ctx.user |> Ecto.Changeset.change(fediverse_followers?: false) |> Repo.update!()

      {:ok, view, _html} = live(ctx.conn, ~p"/feed")

      # The heart is shown anyway: hiding it would leave them no way to find
      # out that this exists and is one setting away.
      html = view |> element("[data-remote-act='like']") |> render_click()

      # The wording is the one every other Fediverse refusal uses, and it must
      # not claim the switch is off — `federated?/1` is also false for an
      # unconfirmed address or a frozen account, whose switch is already on.
      assert html =~ VutuvWeb.FediverseComponents.refusal_message(:not_federating)
      refute has_element?(view, "[data-remote-act='like'][data-on='on']")
      # And no marker is written for a like that never left.
      assert Repo.aggregate(Vutuv.Fediverse.PostLike, :count) == 0
    end
  end

  test "a followers-only post wears the lock", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    cached_post(user, %{audience: "followers"})

    {:ok, view, _html} = live(conn, ~p"/feed")

    assert has_element?(view, "[data-remote-private]")
  end

  test "a content warning stays closed until it is opened", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    cached_post(user, %{summary: "Politics", sensitive: true})

    {:ok, view, html} = live(conn, ~p"/feed")

    assert has_element?(view, "[data-remote-warning]")
    assert html =~ "Politics"
  end

  test "a muted word collapses it to the placeholder, and reveal opens it", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    {:ok, _filter} =
      Vutuv.ContentFilters.create_filter(user, %{"kind" => "keyword", "pattern" => "thought"})

    post = cached_post(user)

    {:ok, view, _html} = live(conn, ~p"/feed")

    assert has_element?(view, "[data-filtered-post]")
    refute has_element?(view, "[data-remote-post='#{post.id}']")

    view |> element("[data-filtered-post] button, [data-filtered-post] a") |> render_click()

    assert has_element?(view, "[data-remote-post='#{post.id}']")
  end

  test "reporting deletes our copy and drops the row", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    post = cached_post(user)

    {:ok, view, _html} = live(conn, ~p"/feed")

    view
    |> element("[data-remote-post='#{post.id}'] [phx-click='report-remote-post']")
    |> render_click()

    assert Repo.aggregate(RemotePost, :count) == 0
    refute has_element?(view, "[data-remote-post='#{post.id}']")
    # The takedown is on record, without any of what was said.
    assert [event] = Fediverse.recent_note_events()
    assert event.action == "reported_post"
  end

  test "a remote post arriving on a later page", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    # Older than everything below, so it lands on the SECOND page — which is
    # what puts it through the "already on screen?" scan that runs over a newly
    # loaded page and reaches for `entry.post.id`, a field a cached remote post
    # does not have.
    cached_post(user, %{published_at: DateTime.add(DateTime.utc_now(:second), -3600)})

    for n <- 1..21, do: Vutuv.PostsHelpers.create_post!(user, %{"body" => "Mine #{n}."})

    {:ok, view, html} = live(conn, ~p"/feed")

    refute html =~ "A thought from over there."
    assert has_element?(view, "#load-more")

    view |> element("#load-more") |> render_click()

    assert has_element?(view, "[data-remote-post]")
  end

  test "the card names where it came from up in the header, not only below the text", %{
    conn: conn
  } do
    {conn, user} = create_and_login_user(conn)
    cached_post(user)

    {:ok, view, _html} = live(conn, ~p"/feed")

    # In a flat feed nothing else says "not a member": the reply card can leave
    # this to its footer because it is visibly indented under a member's post.
    assert has_element?(view, "[data-remote-network='social.example']")
  end

  test "the header wraps on a phone as name + chip over the meta line", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    cached_post(user)

    {:ok, view, _html} = live(conn, ~p"/feed")

    # The chip is the NAME's neighbour, not the row's last item. Trailing the
    # whole header it was the first thing a narrow column pushed onto a line of
    # its own, under the handle and the stamp — a stray pill hanging below the
    # header with nothing beside it. Bound to the name it shares the first line
    # (both are short) and the phone gets two clean lines instead of three.
    assert has_element?(view, "[data-remote-author] + [data-remote-network]")

    # And whenever it does wrap, the lines are set apart. `gap-x-2` alone left
    # a wrapped row with literally zero vertical gap.
    header = view |> element("[data-remote-header]") |> render()
    assert [opening_tag] = Regex.run(~r/^<div[^>]*>/, header)
    assert opening_tag =~ "gap-y-"
  end

  test "muting the account takes its posts out of the feed and keeps the follow", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    post = cached_post(user)

    {:ok, view, _html} = live(conn, ~p"/feed")

    view
    |> element("[data-remote-post='#{post.id}'] [phx-click='mute-remote-account']")
    |> render_click()

    refute has_element?(view, "[data-remote-post='#{post.id}']")
    # Private and reversible: the post is still cached and the follow still
    # stands. This is the lever Report must not be the only alternative to.
    assert Repo.aggregate(RemotePost, :count) == 1
    assert Fediverse.remote_follow_count(user) == 1
    assert Fediverse.feed_remote_posts(user, 10, nil) == []
    # And the timeline says it is empty rather than leaving a blank card.
    assert render(view) =~ "Nothing here yet"
  end

  test "nobody else's feed carries it", %{conn: conn} do
    # The follow is somebody else's, so the cache is somebody else's to read.
    cached_post(insert(:activated_user, fediverse_followers?: true))

    {conn, _stranger} = create_and_login_user(conn)

    {:ok, view, _html} = live(conn, ~p"/feed")

    refute has_element?(view, "[data-remote-post]")
  end

  describe "the closing hashtag line" do
    # A tag this installation really carries, so the chip may link to its page.
    # The name is minted per call with an underscore rather than the factory's
    # hyphenated `unique_tag_name/1`: a hashtag is `[\p{L}\p{N}_]+`, so
    # "#tag-7" would parse as "#tag" — and a hardcoded literal would deadlock
    # against another async module inserting the same one.
    defp linkable_tag do
      name = "Berlin_#{System.unique_integer([:positive])}"
      tag = insert(:tag, name: name, slug: String.downcase(name))
      insert(:user_tag, user: insert(:activated_user), tag: tag)
      tag
    end

    test "becomes tag chips instead of a run of words in the prose", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      tag = linkable_tag()

      post =
        cached_post(user, %{
          content_text: "Kamen die Gespräche zu spät?\n\n##{tag.name} #Anschlag"
        })

      {:ok, view, _html} = live(conn, ~p"/feed")

      card = "[data-remote-post='#{post.id}']"

      assert has_element?(view, "#{card} [data-remote-tags]")
      # A tag we carry reaches its page, the same link a member post's chip has.
      assert has_element?(
               view,
               "#{card} a[data-remote-tag='#{tag.name}'][href='/tags/#{tag.slug}']"
             )

      # One we do not carry is still shown, just not as a link to an empty page.
      assert has_element?(view, "#{card} span[data-remote-tag='Anschlag']")
      # And the line itself is gone from the body.
      refute has_element?(view, "#{card} .markdown a.hashtag")
      refute render(view) =~ "##{tag.name}"
      assert render(view) =~ "Kamen die Gespräche zu spät?"
    end

    test "a hashtag inside a sentence stays in the sentence", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      tag = linkable_tag()

      post = cached_post(user, %{content_text: "Mehr zu ##{tag.name} gibt es hier"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      card = "[data-remote-post='#{post.id}']"

      refute has_element?(view, "#{card} [data-remote-tags]")
      assert has_element?(view, "#{card} .markdown a.hashtag[href='/tags/#{tag.slug}']")
    end

    test "a warned post keeps its chips behind the lid", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post =
        cached_post(user, %{
          summary: "Politics",
          sensitive: true,
          content_text: "Schwerer Stoff.\n\n#Anschlag"
        })

      {:ok, view, _html} = live(conn, ~p"/feed")

      # The tags of a post its author covered up are part of what they covered.
      assert has_element?(
               view,
               "[data-remote-post='#{post.id}'] [data-remote-warning] [data-remote-tags]"
             )
    end

    test "a post that is only hashtags renders as chips and no empty body", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = cached_post(user, %{content_text: "#Anschlag #Berlin"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      card = "[data-remote-post='#{post.id}']"

      assert has_element?(view, "#{card} [data-remote-tag='Anschlag']")
      refute has_element?(view, "#{card} .markdown")
    end
  end
end
