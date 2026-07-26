defmodule VutuvWeb.PhotoCheckProgressTest do
  @moduledoc """
  The "we are checking your photos" indicator (issue #1104).

  A multi-photo post can sit in the AI image scan for a while, and a card that
  simply shows nothing while it waits reads as broken. So the author gets a
  turning hourglass and a count that ticks off as each photo clears — and the
  whole thing has to remove itself when the last verdict lands, with no
  reload. That last part is what most of this file is about.
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
    test "says the post is not public yet and counts the photos that are through", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      {_post, _images} = photo_post!(user, ["approved", "approved", "pending"])

      {:ok, live, _html} = live(conn, ~p"/feed")
      html = live |> element("#feed-posts") |> render()

      assert html =~ "data-image-pending-pill"
      assert html =~ ~s(data-check-pending="1")
      # The fact the author would otherwise get wrong comes first.
      assert html =~ "Only you can see this post so far."
      assert html =~ "2 of 3 done"
      assert html =~ "goes live by itself"
      # The moving part: a still card is what reads as stuck.
      assert html =~ "hourglass"
    end

    test "a single photo is not counted at people, it is just named", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_post, _images} = photo_post!(user, ["pending"])

      html = live_feed_html(conn)

      assert html =~ "Our AI is checking the photo."
      refute html =~ "of 1 done"
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
