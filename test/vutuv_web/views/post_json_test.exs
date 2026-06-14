defmodule VutuvWeb.PostJSONTest do
  @moduledoc """
  The API serialization contract — and the guard that the deny array is the
  author's private configuration: anyone else gets at most `restricted: true`.
  """
  use Vutuv.DataCase

  alias Vutuv.Posts
  alias VutuvWeb.PostJSON

  test "serializes a post with images, tags and the author's audience" do
    author = insert(:user, email_confirmed?: true)
    denied = insert(:user, email_confirmed?: true)
    image = insert(:post_image, user: author, post: nil, alt: "Sunset", width: 400, height: 300)

    {:ok, post} =
      Posts.create_post(author, %{
        body: "**Hi** there",
        tags: "elixir",
        image_ids: [image.id],
        denials: [%{"denied_user_id" => denied.id}, %{"wildcard" => "non_followers"}]
      })

    json = PostJSON.post(post, author)

    assert json.id == post.id
    assert json.url =~ "/#{author.active_slug}/"
    assert String.ends_with?(json.url, Posts.path(post))
    assert json.author.slug == author.active_slug
    assert json.body_markdown == "**Hi** there"
    assert json.body_html =~ "<strong>Hi</strong>"
    assert String.ends_with?(json.published_at, "Z")
    assert json.tags == ["elixir"]

    assert [img] = json.images
    assert img.alt == "Sunset"
    assert {img.width, img.height} == {400, 300}
    assert img.urls.feed == "/post_images/#{image.token}/feed.avif"

    assert %{default: "allow", deny: deny} = json.audience
    assert %{type: "user"} = Enum.find(deny, &(&1.type == "user"))
    assert %{type: "wildcard", value: "non_followers"} = Enum.find(deny, &(&1.type == "wildcard"))
  end

  test "serializes the reply reference through its three states" do
    parent_author =
      insert(:user, email_confirmed?: true, first_name: "Petra", last_name: "Parent")

    replier = insert(:user, email_confirmed?: true)

    {:ok, parent} = Posts.create_post(parent_author, %{body: "the root"})
    {:ok, reply} = Posts.create_reply(replier, parent, %{body: "the answer"})

    assert PostJSON.post(parent, nil).in_reply_to == nil
    assert PostJSON.post(parent, nil).reply_count == 1

    json = PostJSON.post(reply, nil)
    assert json.reply_count == 0
    assert json.in_reply_to.post_id == parent.id
    assert String.ends_with?(json.in_reply_to.url, Posts.path(parent))
    assert json.in_reply_to.author == %{slug: parent_author.active_slug, name: "Petra Parent"}

    # Parent deleted, account alive: no post left, the author still named.
    {:ok, _} = Posts.delete_post(parent)
    json = PostJSON.post(Posts.get_post(reply.id), nil)
    assert json.in_reply_to.post_id == nil
    assert json.in_reply_to.url == nil
    assert json.in_reply_to.author.slug == parent_author.active_slug

    # Account gone too (the real cascade): nothing nameable remains.
    Repo.delete!(parent_author)
    json = PostJSON.post(Posts.get_post(reply.id), nil)
    assert json.in_reply_to == %{post_id: nil, url: nil, author: nil}
  end

  test "the deny array never serializes for other viewers" do
    author = insert(:user, email_confirmed?: true)

    {:ok, restricted} =
      Posts.create_post(author, %{body: "x", denials: [%{"wildcard" => "logged_out"}]})

    {:ok, open} = Posts.create_post(author, %{body: "y"})

    stranger = insert(:user)
    assert PostJSON.post(restricted, stranger).audience == %{restricted: true}
    assert PostJSON.post(restricted, nil).audience == %{restricted: true}
    assert PostJSON.post(open, stranger).audience == %{restricted: false}
  end
end
