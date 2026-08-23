defmodule VutuvWeb.FediversePostLiveTest do
  @moduledoc """
  The page for vutuv's copy of one post from another network
  (`/system/fediverse/post/:id`): who may open it, that the card's stamp leads
  here, and that the handle beside it no longer repeats the server the chip
  already names.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost

  @actor "https://ard.social/users/tagesschau"

  defp account do
    Repo.insert!(%RemoteAccount{
      actor_uri: @actor,
      host: "ard.social",
      handle: "tagesschau",
      name: "tagesschau",
      inbox_uri: @actor <> "/inbox"
    })
  end

  defp follow(user, account, state \\ "accepted") do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: state,
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{account.id}"
    })
  end

  defp cached_post(account, attrs \\ %{}) do
    now = DateTime.utc_now(:second)

    Repo.insert!(
      struct(
        %RemotePost{
          remote_account_id: account.id,
          object_uri: "https://ard.social/posts/#{System.unique_integer([:positive])}",
          content_text: "Die Nachrichten von heute.",
          audience: "public",
          kind: "note",
          published_at: now,
          received_at: now,
          expires_at: DateTime.add(now, 86_400)
        },
        attrs
      )
    )
  end

  test "an anonymous visitor is sent to the login", %{conn: conn} do
    post = cached_post(account())

    conn = get(conn, ~p"/system/fediverse/post/#{post.id}")
    assert redirected_to(conn) == ~p"/login"
  end

  test "robots are told not to index it", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    post = cached_post(account())

    conn = get(conn, ~p"/system/fediverse/post/#{post.id}")

    # Somebody else's words on somebody else's server: our copy is a members'
    # page, not something this installation publishes.
    assert [robots] = Plug.Conn.get_resp_header(conn, "x-robots-tag")
    assert robots =~ "noindex"
  end

  test "an unknown id lands on the feed instead of crashing", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    assert {:error, {:redirect, %{to: "/feed"}}} =
             live(conn, ~p"/system/fediverse/post/019fa2ba-b301-771a-8bbf-efd42278fd8a")
  end

  test "it shows the post, the network it came from and the way to the account",
       %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    acc = account()
    post = cached_post(acc)

    {:ok, view, html} = live(conn, ~p"/system/fediverse/post/#{post.id}")

    assert html =~ "Die Nachrichten von heute."
    assert html =~ "ard.social"
    assert has_element?(view, ~s{a[href="/system/fediverse/account/#{acc.id}"]})
    # The address that does not expire, since our copy can be swept away.
    assert has_element?(view, ~s{[data-remote-origin][href="#{post.object_uri}"]})
  end

  test "a followers-only post opens for an accepted follower and 404s for anyone else",
       %{conn: conn} do
    acc = account()
    post = cached_post(acc, %{audience: "followers"})

    {follower_conn, follower} = create_and_login_user(conn)
    follow(follower, acc)

    assert {:ok, _view, html} = live(follower_conn, ~p"/system/fediverse/post/#{post.id}")
    assert html =~ "Die Nachrichten von heute."

    {stranger_conn, stranger} =
      create_and_login_user(Plug.Test.init_test_session(build_conn(), %{}))

    # A request nobody answered is not a relationship.
    follow(stranger, acc, "requested")

    assert {:error, {:redirect, %{to: "/feed"}}} =
             live(stranger_conn, ~p"/system/fediverse/post/#{post.id}")
  end

  test "it reads properly in German", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    post = cached_post(account())
    conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de;q=0.9")

    {:ok, _view, html} = live(conn, ~p"/system/fediverse/post/#{post.id}")

    # Named by hand, because `gettext.extract --merge` fuzzy-filled this page's
    # heading with "Reaktion aus einem anderen Netzwerk" — a reaction, which is
    # a different thing entirely, and nothing fails a build over it.
    assert html =~ "Ein Beitrag aus einem anderen Netzwerk"
    assert html =~ "Das ist die Kopie, die vutuv"
    assert html =~ "Mehr von tagesschau"
  end

  describe "the card header" do
    test "the stamp links here and the handle drops the server the chip names",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      acc = account()
      follow(user, acc)
      post = cached_post(acc)

      {:ok, view, html} = live(conn, ~p"/feed")

      # The stamp is the way to our copy's own page, exactly as on a member's
      # post.
      assert has_element?(
               view,
               ~s{a[data-remote-permalink][href="/system/fediverse/post/#{post.id}"]}
             )

      # Shortened, because the globe chip at the end of the same row already
      # says "ard.social" — with the full address one hover away.
      assert has_element?(view, ~s{a[title="@tagesschau@ard.social"]})
      refute html =~ ">@tagesschau@ard.social<"
    end

    test "an anonymous reader keeps a plain stamp rather than a link into a login wall" do
      acc = account()
      post = cached_post(acc)

      html =
        render_component(&VutuvWeb.PostComponents.remote_post_card/1,
          remote_post: %{post | remote_account: acc},
          viewer: nil
        )

      refute html =~ "data-remote-permalink"
      assert html =~ "@tagesschau"
    end
  end

  describe "the origin's own figures (issue #1283)" do
    test "the bar shows them", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      post = cached_post(account(), %{likes_count: 12, shares_count: 3})

      {:ok, view, _html} = live(conn, ~p"/system/fediverse/post/#{post.id}")

      assert render(element(view, ~s{[data-remote-count="like"]})) =~ "12"
      assert render(element(view, ~s{[data-remote-count="repost"]})) =~ "3"
    end

    test "a server that tells us nothing gets no figure, not a zero", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      post = cached_post(account())

      {:ok, view, _html} = live(conn, ~p"/system/fediverse/post/#{post.id}")

      # The heart is there; the number beside it is not.
      assert has_element?(view, ~s{[data-remote-act="like"]})
      refute has_element?(view, ~s{[data-remote-count]})
    end

    test "a figure that moves upstream ticks on the open page", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      post = cached_post(account(), %{likes_count: 12, shares_count: 3})

      {:ok, view, _html} = live(conn, ~p"/system/fediverse/post/#{post.id}")

      Phoenix.PubSub.broadcast(
        Vutuv.PubSub,
        Vutuv.Fediverse.counts_topic(),
        {:fediverse_counts, :remote_post, post.id, %{likes: 40, shares: 5}}
      )

      # The hook forwards with `send_update/2`, which LiveView applies on the
      # next message it handles — so the first render is what carries it out and
      # the second is what can see the result.
      render(view)

      assert render(element(view, ~s{[data-remote-count="like"]})) =~ "40"
      assert render(element(view, ~s{[data-remote-count="repost"]})) =~ "5"
    end

    test "a figure about another post leaves this page alone", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      acc = account()
      post = cached_post(acc, %{likes_count: 12})
      other = cached_post(acc, %{likes_count: 1})

      {:ok, view, _html} = live(conn, ~p"/system/fediverse/post/#{post.id}")

      Phoenix.PubSub.broadcast(
        Vutuv.PubSub,
        Vutuv.Fediverse.counts_topic(),
        {:fediverse_counts, :remote_post, other.id, %{likes: 99, shares: nil}}
      )

      render(view)

      assert render(element(view, ~s{[data-remote-count="like"]})) =~ "12"
    end
  end

  describe "the optimistic flip, gated on the reader's own standing" do
    # A press on a card from another network paints on the spot the way the
    # vutuv bar does — but only where it is going to succeed. Taking part in the
    # Fediverse is opt-in and most readers have not switched it on, so for them
    # a heart that fills and empties again on every press would be worse than
    # the explanation the bar prints instead.
    defp federating_member(conn) do
      {conn, user} = create_and_login_user(conn)
      user = user |> Ecto.Changeset.change(fediverse_followers?: true) |> Repo.update!()
      {conn, user}
    end

    test "a member who takes part gets the flip", %{conn: conn} do
      {conn, _user} = federating_member(conn)
      post = cached_post(account(), %{likes_count: 12})

      {:ok, view, _html} = live(conn, ~p"/system/fediverse/post/#{post.id}")
      like = render(element(view, ~s{[data-remote-act="like"]}))

      assert like =~ "toggle_class"
      assert like =~ "toggle_attr"
      assert like =~ "text-accent"
      # The origin's figure moves with the press, both steps pre-rendered.
      assert like =~ "data-count-off"
      assert like =~ "data-count-on"
    end

    test "a member who does not take part keeps the plain press", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      post = cached_post(account(), %{likes_count: 12})

      {:ok, view, _html} = live(conn, ~p"/system/fediverse/post/#{post.id}")
      like = render(element(view, ~s{[data-remote-act="like"]}))

      assert like =~ ~s(phx-click="toggle")
      refute like =~ "toggle_class"
    end

    # Saving never leaves the building (`check_bookmark/2` asks only whether the
    # reader may read the post), so it paints for everyone.
    test "the bookmark paints even for a member who does not take part", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      post = cached_post(account())

      {:ok, view, _html} = live(conn, ~p"/system/fediverse/post/#{post.id}")
      bookmark = render(element(view, ~s{[data-remote-act="bookmark"]}))

      assert bookmark =~ "toggle_class"
      assert bookmark =~ ~s(data-on)
    end

    test "a server that serves no figure gets no count toggle to go with it", %{conn: conn} do
      {conn, _user} = federating_member(conn)
      post = cached_post(account())

      {:ok, view, _html} = live(conn, ~p"/system/fediverse/post/#{post.id}")
      like = render(element(view, ~s{[data-remote-act="like"]}))

      # The state still flips; predicting a tally nobody gave us does not.
      assert like =~ "toggle_class"
      refute like =~ "data-count-off"
    end

    test "both steps of the origin's figure are formatted by the server", %{conn: conn} do
      {conn, _user} = federating_member(conn)
      post = cached_post(account(), %{likes_count: 999})

      {:ok, view, _html} = live(conn, ~p"/system/fediverse/post/#{post.id}")
      like = render(element(view, ~s{[data-remote-act="like"]}))

      # 999 → "1K" is `compact_count/1`'s work and it is locale-aware, so the
      # client is never asked to re-derive it.
      assert like =~ ~r/data-remote-count="like">\s*999\s*</
      assert like =~ ~r/data-count-on[^>]*>\s*1K\s*</
    end
  end
end
