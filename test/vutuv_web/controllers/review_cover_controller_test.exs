defmodule VutuvWeb.ReviewCoverControllerTest do
  @moduledoc """
  The authorizing review-cover proxy: the post's audience must guard the
  cover bytes, a cover still in AI-moderation limbo is the author's alone,
  and only the currently stored fingerprinted filename resolves. Denied and
  unknown both answer 404.
  """

  use VutuvWeb.ConnCase

  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.ReviewCover

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_covers_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      if prev,
        do: Application.put_env(:vutuv, :uploads_dir_prefix, prev),
        else: Application.delete_env(:vutuv, :uploads_dir_prefix)
    end)

    :ok
  end

  defp jpeg_bytes do
    path = Path.join(System.tmp_dir!(), "cover_src_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(120, 180, color: [10, 120, 200])
    {:ok, _} = Image.write(img, path)
    bytes = File.read!(path)
    File.rm(path)
    bytes
  end

  defp reviewed_post!(author, post_attrs \\ %{}, review_overrides \\ %{}) do
    {:ok, post} =
      Posts.create_post(
        author,
        Map.merge(
          %{
            body: "Lesenswert",
            review: %{
              "kind" => "book",
              "identifier" => "978-3-16-148410-0",
              "title" => "Refactoring"
            }
          },
          post_attrs
        )
      )

    {:ok, file} = ReviewCover.store_binary(jpeg_bytes(), post.review)

    review =
      post.review
      |> Ecto.Changeset.change(
        Map.merge(
          %{cover: file, cover_status: "ready", cover_moderation: "approved"},
          review_overrides
        )
      )
      |> Repo.update!()

    {post, review}
  end

  defp cover_path(review), do: ReviewCover.url(review)

  test "a public post's cover is served with immutable private caching", %{conn: conn} do
    author = insert(:user, email_confirmed?: true)
    {_post, review} = reviewed_post!(author)

    conn = get(conn, cover_path(review))

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/avif"
    assert get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]
    # Somebody else's book cover, quoted here at thumbnail size — it has no
    # business in an image search under our domain.
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, noimageindex"]
  end

  test "an outdated or foreign filename never resolves", %{conn: conn} do
    author = insert(:user, email_confirmed?: true)
    {_post, review} = reviewed_post!(author)

    assert conn |> get("/review_covers/#{review.id}/cover-000000000000.avif") |> response(404)
    assert conn |> get("/review_covers/#{review.id}/original.jpg") |> response(404)

    assert conn
           |> get("/review_covers/#{Vutuv.UUIDv7.generate()}/cover-abc.avif")
           |> response(404)
  end

  test "a restricted post's cover is denied to strangers but served to the author", %{conn: conn} do
    {authed_conn, author} = create_and_login_user(conn)

    {_post, review} =
      reviewed_post!(author, %{denials: [%{"wildcard" => "non_followers"}]})

    assert conn |> get(cover_path(review)) |> response(404)
    assert authed_conn |> get(cover_path(review)) |> response(200)
  end

  test "a cover in moderation limbo is the author's alone", %{conn: conn} do
    {authed_conn, author} = create_and_login_user(conn)
    {_post, review} = reviewed_post!(author, %{}, %{cover_moderation: "pending"})

    assert conn |> get(cover_path(review)) |> response(404)
    assert authed_conn |> get(cover_path(review)) |> response(200)
  end
end
