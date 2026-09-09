defmodule VutuvWeb.OgImageControllerTest do
  @moduledoc """
  GET /:slug/og.png and /:slug/posts/:id/og.png — the generated link-preview
  cards behind `og:image` on a member's pages (`VutuvWeb.OgImage`). Drawn
  from the anonymous public view only, so a withheld profile and a post an
  anonymous reader may not see answer the same plain 404.
  """
  # Not async: points the global :uploads_dir_prefix at a tmp dir for the
  # member-with-avatar case.
  use VutuvWeb.ConnCase, async: false

  import Vutuv.PostsHelpers

  alias Vutuv.ImageHelpers
  alias Vutuv.Posts

  setup %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_og_image_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      if prev,
        do: Application.put_env(:vutuv, :uploads_dir_prefix, prev),
        else: Application.delete_env(:vutuv, :uploads_dir_prefix)
    end)

    {:ok, conn: conn}
  end

  defp member_with_avatar(attrs) do
    user = insert_activated_user(attrs)

    src = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(600, 400, color: [10, 120, 200])
    {:ok, _} = Image.write(img, src)
    on_exit(fn -> File.rm(src) end)

    upload = %Plug.Upload{filename: "selfie.jpg", path: src, content_type: "image/jpeg"}
    {:ok, stored, fingerprint, _moderation} = Vutuv.Avatar.store({upload, user})

    user
    |> Ecto.Changeset.change(avatar: stored, avatar_fingerprint: fingerprint)
    |> Repo.update!()
    |> ImageHelpers.with_image_rows()
  end

  defp png_size(conn) do
    assert conn.status == 200
    assert conn |> get_resp_header("content-type") |> hd() =~ "image/png"
    assert conn |> get_resp_header("cache-control") |> hd() == "public, max-age=86400"
    {:ok, img} = Image.open(conn.resp_body)
    {Image.width(img), Image.height(img)}
  end

  describe "GET /:slug/og.png" do
    test "draws the member's card, 1200×630, with their picture", %{conn: conn} do
      user = member_with_avatar(first_name: "Ava", last_name: "Card", locale: "de")
      insert(:work_experience, user: user, title: "Developer", organization: "Acme Corp")

      assert conn |> get("/#{user.username}/og.png") |> png_size() == {1200, 630}
    end

    test "draws a card for a member without a picture too", %{conn: conn} do
      user = insert_activated_user(first_name: "Bare")

      assert conn |> get("/#{user.username}/og.png") |> png_size() == {1200, 630}
    end

    test "an unknown slug and a withheld profile are plain 404s", %{conn: conn} do
      hidden =
        insert_activated_user(first_name: "Hidden")
        |> Ecto.Changeset.change(
          suspended_until: NaiveDateTime.add(NaiveDateTime.utc_now(:second), 86_400)
        )
        |> Repo.update!()

      assert conn |> get("/no-such-member/og.png") |> Map.fetch!(:status) == 404
      assert conn |> get("/#{hidden.username}/og.png") |> Map.fetch!(:status) == 404
    end
  end

  describe "GET /:slug/posts/:id/og.png" do
    test "draws the post's card", %{conn: conn} do
      author = insert_activated_user(first_name: "Paula")
      post = create_post!(author, %{"body" => "Hello **preview** world.\n\nSecond paragraph."})

      assert conn |> get(Posts.path(post) <> "/og.png") |> png_size() == {1200, 630}
    end

    test "draws the square card for LinkedIn's thumbnail", %{conn: conn} do
      author = insert_activated_user(first_name: "Paula")
      post = create_post!(author, %{"body" => "Hello preview world, and a few more words."})

      assert conn |> get(Posts.path(post) <> "/og-square.png") |> png_size() == {1200, 1200}
    end

    test "resolves the post by its id, whatever handle stands beside it", %{conn: conn} do
      author = insert_activated_user(first_name: "Paula")
      post = create_post!(author, %{"body" => "Hello preview world."})

      assert conn |> get("/somebody-else/posts/#{post.id}/og.png") |> png_size() == {1200, 630}
    end

    test "a restricted post has no card, and neither has an unknown id", %{conn: conn} do
      author = insert_activated_user()

      post =
        create_post!(author, %{
          "body" => "members only",
          "denials" => [%{"wildcard" => "logged_out"}]
        })

      assert conn |> get(Posts.path(post) <> "/og.png") |> Map.fetch!(:status) == 404
      assert conn |> get(Posts.path(post) <> "/og-square.png") |> Map.fetch!(:status) == 404

      assert conn
             |> get("/#{author.username}/posts/#{Vutuv.UUIDv7.generate()}/og.png")
             |> Map.fetch!(:status) == 404
    end
  end
end
