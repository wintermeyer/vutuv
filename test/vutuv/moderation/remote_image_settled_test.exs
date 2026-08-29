defmodule Vutuv.Moderation.RemoteImageSettledTest do
  @moduledoc """
  A cached post's picture leaving the AI gate is announced on the post's topic,
  so a card already on screen stops saying "picture is being checked".

  Until this, `apply_approved/1` for `remote_post_image` was a bare
  `update_all`. Every other kind announces its verdict through
  `Vutuv.Activity.broadcast(scan.owner_user_id, …)`, and a picture fetched from
  another network has no owner here, so nothing was sent at all: a card kept
  the tile it was first drawn with until the reader reloaded the page. That is
  not a corner case — the card is drawn in the second between the picture being
  recorded and its bytes landing, so the grey tile is the *normal* first draw
  of a boosted photo post.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Moderation.ImageScan
  alias Vutuv.Moderation.ImageSubjects

  defp waiting_picture(attrs \\ []) do
    post = remote_account() |> cached_post()

    image =
      Repo.insert!(%RemoteImage{
        remote_post_id: post.id,
        source_uri: "https://social.example/media/#{System.unique_integer([:positive])}.jpg",
        file: attrs[:file] || "img-abc.avif",
        moderation: "pending"
      })

    {post, image}
  end

  defp scan_for(%RemoteImage{} = image, fingerprint) do
    %ImageScan{kind: "remote_post_image", subject_id: image.id, fingerprint: fingerprint}
  end

  test "an approved picture is announced with its post id" do
    {post, image} = waiting_picture()
    Fediverse.subscribe_remote_images()

    assert :ok = ImageSubjects.apply_approved(scan_for(image, image.file))

    assert_receive {:remote_images_settled, %{remote_post_id: id}}
    assert id == post.id
    assert Repo.get!(RemoteImage, image.id).moderation == "approved"
  end

  test "a rejected picture is announced too" do
    # A rejection changes the row a card was drawn from just as much, so every
    # card showing it has to re-read. What the tile then says about a picture
    # that will never arrive is a separate wrong answer, not this one's.
    {post, image} = waiting_picture()
    Fediverse.subscribe_remote_images()

    assert :ok = ImageSubjects.apply_rejected(scan_for(image, image.file))

    assert_receive {:remote_images_settled, %{remote_post_id: id}}
    assert id == post.id
  end

  test "a verdict that lost its race announces nothing" do
    # The picture was refetched while the model was looking at the old bytes, so
    # the flip touches no row. Announcing anyway would send every open card back
    # to the database for a state that has not changed.
    {_post, image} = waiting_picture()
    Fediverse.subscribe_remote_images()

    assert :stale = ImageSubjects.apply_approved(scan_for(image, "img-stale.avif"))

    refute_receive {:remote_images_settled, _}
  end

  test "a picture whose post is already gone announces nothing and does not raise" do
    # The retention sweep can take the post (and its pictures) while the model
    # is still looking. There is then no post id to name and nothing to say.
    {_post, image} = waiting_picture()
    Fediverse.subscribe_remote_images()
    Repo.delete!(image)

    assert :stale = ImageSubjects.apply_approved(scan_for(image, image.file))

    refute_receive {:remote_images_settled, _}
  end
end
