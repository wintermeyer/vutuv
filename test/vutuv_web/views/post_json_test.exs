defmodule VutuvWeb.PostJSONTest do
  @moduledoc """
  The API serialization contract — and the guard that the deny array is the
  author's private configuration: anyone else gets at most `restricted: true`.
  """
  use Vutuv.DataCase

  alias Vutuv.Posts
  alias VutuvWeb.PostJSON

  test "serializes a post with images, tags and the author's audience" do
    author = insert(:user, validated?: true)
    group = insert(:group, user: author, name: "Inner circle")
    image = insert(:post_image, user: author, post: nil, alt: "Sunset", width: 400, height: 300)

    {:ok, post} =
      Posts.create_post(author, %{
        body: "**Hi** there",
        tags: "elixir",
        image_ids: [image.id],
        denials: [%{"group_id" => group.id}, %{"wildcard" => "non_followers"}]
      })

    json = PostJSON.post(post, author)

    assert json.id == post.id
    assert json.slug == Vutuv.Posts.Post.slug(post)
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
    assert %{type: "group", name: "Inner circle"} = Enum.find(deny, &(&1.type == "group"))
    assert %{type: "wildcard", value: "non_followers"} = Enum.find(deny, &(&1.type == "wildcard"))
  end

  test "the deny array never serializes for other viewers" do
    author = insert(:user, validated?: true)

    {:ok, restricted} =
      Posts.create_post(author, %{body: "x", denials: [%{"wildcard" => "logged_out"}]})

    {:ok, open} = Posts.create_post(author, %{body: "y"})

    stranger = insert(:user)
    assert PostJSON.post(restricted, stranger).audience == %{restricted: true}
    assert PostJSON.post(restricted, nil).audience == %{restricted: true}
    assert PostJSON.post(open, stranger).audience == %{restricted: false}
  end
end
