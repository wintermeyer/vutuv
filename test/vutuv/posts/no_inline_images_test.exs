defmodule Vutuv.Posts.NoInlineImagesTest do
  @moduledoc """
  A picture no longer goes into a post's text: a photo is an attachment and
  shows as the gallery below the post. The editor refuses a dropped or pasted
  file, and this is the storage half — the Markdown source mode would
  otherwise still take a hand-typed `![](/post_images/…)`.

  A post written before keeps what it has: an edit may keep its inline
  pictures, it just cannot add one.
  """

  use Vutuv.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostImage
  alias Vutuv.Repo

  setup do
    user = insert_activated_user()
    image = insert(:post_image, user: user, post: nil)
    %{user: user, image: image, ref: "![](#{PostImage.url(image, "feed")})"}
  end

  test "a new post cannot embed a picture in its text", %{user: user, image: image, ref: ref} do
    assert {:error, changeset} =
             Posts.create_post(user, %{body: "Seht mal #{ref}", image_ids: [image.id]})

    assert %{body: [_]} = errors_on(changeset)
  end

  test "an older post keeps its inline picture through an edit, but gains no new one", %{
    user: user,
    image: image,
    ref: ref
  } do
    {:ok, post} = Posts.create_post(user, %{body: "Vorher", image_ids: [image.id]})

    # What a post from before looks like: the reference already stored.
    Repo.update_all(from(p in Post, where: p.id == ^post.id), set: [body: "Alt #{ref}"])
    post = Repo.get!(Post, post.id)

    assert {:ok, _} = Posts.update_post(post, %{body: "Alt, bearbeitet #{ref}"})

    other = insert(:post_image, user: user, post: nil)
    added = "![](#{PostImage.url(other, "feed")})"

    assert {:error, changeset} =
             Posts.update_post(Repo.get!(Post, post.id), %{body: "Alt #{ref} #{added}"})

    assert %{body: [_]} = errors_on(changeset)
  end

  test "image syntax inside code stays sample text", %{user: user} do
    assert {:ok, _} = Posts.create_post(user, %{body: "So geht's: `![](/x.png)`"})
  end
end
