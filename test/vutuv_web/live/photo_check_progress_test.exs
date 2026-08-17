defmodule VutuvWeb.PhotoCheckProgressTest do
  @moduledoc """
  The two faces of a photo waiting for the AI image scan (issue #1104).

  A multi-photo post can sit in the scan for a while, and a card that simply
  shows nothing while it waits reads as broken. The post itself is published
  from the moment it is written, so **two** readers have to be told what is
  going on, in two different voices: the author gets the amber panel (a turning
  hourglass, a count that ticks off, and the fact they would otherwise get
  wrong — the post is out, the photo is not), everybody else gets the placecard
  standing where the picture goes. Both have to remove themselves when the
  verdict lands, with no reload. That last part is what most of this file is
  about.
  """

  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
  alias Vutuv.Repo

  defp photo_post!(user, states) do
    images =
      for {state, index} <- Enum.with_index(states) do
        insert(:post_image,
          user: user,
          post_id: nil,
          moderation: state,
          token: "chk#{index}#{System.unique_integer([:positive])}"
        )
      end

    {:ok, post} =
      Posts.create_post(user, %{body: "A set.", image_ids: Enum.map(images, & &1.id)})

    {post, images}
  end

  describe "the author's progress line" do
    test "says the post is out, the photo is not, and counts what is through", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      {_post, _images} = photo_post!(user, ["approved", "approved", "pending"])

      {:ok, live, _html} = live(conn, ~p"/feed")
      html = live |> element("#feed-posts") |> render()

      assert html =~ "data-image-pending-pill"
      assert html =~ ~s(data-check-pending="1")
      # The fact the author would otherwise get wrong comes first — and it is
      # the opposite of what this panel said while the post was held back.
      assert html =~ "Your post is published, the photo is not there yet."
      refute html =~ "Only you can see this post so far."
      assert html =~ "2 of 3 done"
      assert html =~ "appear by themselves"
      # The moving part: a still card is what reads as stuck.
      assert html =~ "hourglass"
    end

    test "a single photo is not counted at people, it is just named", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_post, _images} = photo_post!(user, ["pending"])

      html = live_feed_html(conn)

      assert html =~ "Our AI is still checking it."
      refute html =~ "of 1 done"
    end

    # It is the author's panel, in the author's voice. A reader who is not the
    # author must never be told "your post" — what they get is the placecard.
    test "is the author's alone; a reader gets the placecard instead", %{conn: conn} do
      author = insert(:user, email_confirmed?: true)
      {post, [held]} = photo_post!(author, ["pending"])

      {conn, reader} = create_and_login_user(conn)
      follow!(reader, author)

      {:ok, live, _html} = live(conn, ~p"/feed")
      html = live |> element("#feed-posts") |> render()

      # The post itself is there — this is the whole change.
      assert html =~ post.id
      refute html =~ "data-image-pending-pill"
      assert html =~ "data-image-placecards"
      assert html =~ "Photo is being checked"
      assert html =~ "Our AI is looking at it."
      # And the unjudged picture is still not served to them.
      refute html =~ "/post_images/#{held.token}/"
    end

    test "never shows once every photo is through", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_post, _images} = photo_post!(user, ["approved", "approved"])

      refute live_feed_html(conn) =~ "data-image-pending-pill"
    end

    defp live_feed_html(conn) do
      {:ok, live, _html} = live(conn, ~p"/feed")
      live |> element("#feed-posts") |> render()
    end
  end

  describe "when the scan finishes" do
    test "the feed clears the indicator and shows the photo, with no reload", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {post, [held]} = photo_post!(user, ["pending"])

      {:ok, live, _html} = live(conn, ~p"/feed")
      assert live |> element("#feed-posts") |> render() =~ "data-image-pending-pill"

      release(held, post)

      html = live |> element("#feed-posts") |> render()
      refute html =~ "data-image-pending-pill"
      assert html =~ "/post_images/#{held.token}/"
    end

    # The reader's side of the same promise. Their feed subscribes to the few
    # posts on the page that are actually waiting (`watch_pending_photos/2`),
    # so the picture arrives where the placecard was without them doing
    # anything — which is what the placecard's "it appears here by itself" says.
    test "a reader's feed swaps the placecard for the photo, with no reload", %{conn: conn} do
      author = insert(:user, email_confirmed?: true)
      {post, [held]} = photo_post!(author, ["pending"])

      {conn, reader} = create_and_login_user(conn)
      follow!(reader, author)

      {:ok, live, _html} = live(conn, ~p"/feed")
      assert live |> element("#feed-posts") |> render() =~ "data-image-placecards"

      release(held, post)

      html = live |> element("#feed-posts") |> render()
      refute html =~ "data-image-placecards"
      assert html =~ "/post_images/#{held.token}/"
    end

    test "the permalink swaps the placecard for the photo for a stranger too", %{conn: _conn} do
      author = insert(:user, email_confirmed?: true)
      {post, [held]} = photo_post!(author, ["pending"])

      # The permalink's conversation is an embedded LiveView the controller
      # renders, so it is mounted on its own here (the thread tests' pattern).
      {:ok, live, html} =
        live_isolated(build_conn(), VutuvWeb.PostLive.Thread,
          session: %{"post_id" => post.id, "locale" => "en"}
        )

      # A stranger sees the neutral placecard, never the unreleased picture.
      assert html =~ "data-image-placecards"
      refute html =~ "/post_images/#{held.token}/"

      release(held, post)

      html = render(live)
      refute html =~ "data-image-placecards"
      assert html =~ "/post_images/#{held.token}/"
    end

    test "the count ticks down one photo at a time", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {post, [first, second]} = photo_post!(user, ["pending", "pending"])

      {:ok, live, _html} = live(conn, ~p"/feed")
      assert live |> element("#feed-posts") |> render() =~ ~s(data-check-pending="2")

      release(first, post)
      assert live |> element("#feed-posts") |> render() =~ ~s(data-check-pending="1")

      release(second, post)
      refute live |> element("#feed-posts") |> render() =~ "data-image-pending-pill"
    end

    # The release path a settled scan takes: flip the row, then tell every open
    # page. Going through `broadcast_images_settled/1` is the point — it is the
    # message `Vutuv.Moderation.ImageSubjects` sends on both the approve and
    # the reject path.
    defp release(image, post) do
      image |> Ecto.Changeset.change(moderation: "approved") |> Repo.update!()
      Posts.broadcast_images_settled(post.id)
      # Let the LiveView process the broadcast before the assertion reads it.
      :sys.get_state(Repo)
      Process.sleep(0)
    end
  end

  # vutuv is a German site, and `mix gettext.extract --merge` fuzzy-fills a new
  # msgid with the translation of whatever old string it resembles: the plural
  # line here came back carrying the *previous* wording ("geht der Beitrag von
  # selbst online" — the post goes live by itself), which is now exactly the
  # thing that is not true. Nothing fails the build over a fuzzy flag, so these
  # sentences are asserted by name on a real German render.
  describe "in German" do
    test "the author is told the post is out and the photo is not", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {post, _images} = photo_post!(user, ["approved", "pending"])

      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> get(Posts.path(Vutuv.Repo.preload(post, :user)))
        |> html_response(200)

      assert html =~ "Ihr Beitrag ist veröffentlicht, das Foto noch nicht."
      assert html =~ "Unsere KI prüft sie gerade, 1 von 2 sind durch."
      refute html =~ "geht der Beitrag von selbst online"
    end

    test "a reader gets the placecard's German", %{conn: conn} do
      author = insert(:user, email_confirmed?: true)
      {post, _images} = photo_post!(author, ["pending"])

      html =
        conn
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> get(Posts.path(Vutuv.Repo.preload(post, :user)))
        |> html_response(200)

      assert html =~ "Foto wird geprüft"

      assert html =~
               "Unsere KI sieht es sich an. Es erscheint hier von selbst, sobald sie durch ist."
    end
  end

  describe "image_check_progress/1" do
    test "counts what is left, from the post's own photos" do
      user = insert(:user)
      {post, _images} = photo_post!(user, ["approved", "pending", "pending"])
      post = Repo.preload(post, :images, force: true)

      assert Posts.image_check_progress(post) == %{total: 3, checked: 1, pending: 2}
    end

    test "an un-preloaded post answers zeroes rather than raising" do
      assert Posts.image_check_progress(%Vutuv.Posts.Post{}) == %{
               total: 0,
               checked: 0,
               pending: 0
             }
    end

    # `post_images.moderation` is `null: false, default: "pending"`, so the
    # grandfathered-NULL rows `released?/1` also accepts cannot occur here —
    # the counter reads the same gate rather than its own idea of "released",
    # which is what keeps the two from drifting.
    test "asks the moderation gate, not its own rule" do
      user = insert(:user)
      {post, _images} = photo_post!(user, ["approved", "pending"])
      post = Repo.preload(post, :images, force: true)

      expected = Enum.count(post.images, &(not ImageScans.released?(&1.moderation)))
      assert Posts.image_check_progress(post).pending == expected
    end
  end

  # A pending image with no post yet (still in somebody's composer) must not
  # send anybody a message about a post that does not exist.
  test "a settled composer image broadcasts nothing" do
    assert Posts.broadcast_images_settled(nil) == :ok
    assert %PostImage{} = insert(:post_image, post_id: nil)
  end
end
