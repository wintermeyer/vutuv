defmodule VutuvWeb.FeedRemoteImageSettlesTest do
  @moduledoc """
  A picture on a cached post leaves the AI gate while a page is open, and the
  card stops saying "picture is being checked" without a reload (issue #1801) —
  on the feed and on the post's own page alike, the two of the six surfaces that
  print the promise where a reader is most likely to be waiting.

  The card's own line promises exactly that ("it appears here by itself once the
  AI is through"), and for a picture from another network it was false: the
  verdict was a database flip nobody was told about. It is the *normal* case,
  not a corner one — a delivery records the picture and nudges the open feeds in
  the same breath, a second before the bytes land, so the reader's first sight
  of a boosted photo post is the wordless waiting tile.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.MastodonHelpers
  import Vutuv.PostsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Posts.PostRemoteReply

  defp followed_post(user) do
    account = remote_account()

    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/1"
    })

    cached_post(account, content_text: "Ein Teil der hier markierten Felsnase.")
  end

  # The same cached post with nobody here following its author: it is held
  # because somebody else does, so it reaches this reader only as the parent
  # their own answer nests — which is the card this test is about.
  defp unfollowed_post, do: cached_post(remote_account(), content_text: "Eine Skizze.")

  defp waiting_picture(post) do
    Repo.insert!(%RemoteImage{
      remote_post_id: post.id,
      source_uri: "https://social.example/media/nepal.png",
      file: nil,
      moderation: "pending"
    })
  end

  # What the AI gate's verdict does to the row, without driving the whole scan:
  # the bytes arrive, the column flips, the release is announced.
  defp release(image) do
    image
    |> Ecto.Changeset.change(file: "img-abc.avif", moderation: "approved")
    |> Repo.update!()

    Fediverse.broadcast_remote_images_settled(image.remote_post_id)
  end

  test "the waiting tile becomes the picture with no reload", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    post = followed_post(user)
    image = waiting_picture(post)

    {:ok, view, html} = live(conn, ~p"/feed")

    # The card is drawn before the bytes are here, so this is what the reader
    # meets first — and until #1801 it was also what they were left with.
    assert html =~ "data-remote-image-pending"
    assert has_element?(view, "[data-remote-images-checking]")

    release(image)

    html = render(view)
    refute html =~ "data-remote-image-pending"
    refute has_element?(view, "[data-remote-images-checking]")
    assert html =~ "/system/remote_media/posts/#{image.id}/img-abc.avif"
  end

  test "a cached post nested as the parent of a member's reply swaps in too", %{conn: conn} do
    # The second card that draws the same wait: the reader's own answer to a
    # photo post out there nests the post it answers, and that nested card
    # carries the tile. Nothing about it is on `entry.remote_post`, so a refresh
    # that walked only the entry's own card would leave it waiting for ever.
    {conn, user} = create_and_login_user(conn)
    post = unfollowed_post()
    image = waiting_picture(post)

    reply = create_post!(user, %{"body" => "Danke für die Skizze."})

    Repo.insert!(%PostRemoteReply{
      post_id: reply.id,
      remote_post_id: post.id,
      in_reply_to_uri: post.object_uri,
      actor_uri: post.remote_account.actor_uri
    })

    {:ok, view, html} = live(conn, ~p"/feed")
    assert html =~ "data-remote-image-pending"

    release(image)

    refute render(view) =~ "data-remote-image-pending"
  end

  test "the post's own page swaps the picture in too", %{conn: conn} do
    # The other surface a reader waits on: they opened this URL *because* of the
    # picture, so a page that keeps the tile until they press reload is the same
    # broken promise the feed made.
    {conn, user} = create_and_login_user(conn)
    post = followed_post(user)
    image = waiting_picture(post)

    {:ok, view, html} = live(conn, ~p"/system/fediverse/post/#{post.id}")
    assert html =~ "data-remote-image-pending"

    release(image)

    html = render(view)
    refute html =~ "data-remote-image-pending"
    assert html =~ "/system/remote_media/posts/#{image.id}/img-abc.avif"
  end
end
