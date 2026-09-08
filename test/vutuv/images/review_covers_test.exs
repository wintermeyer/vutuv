defmodule Vutuv.Images.ReviewCoversTest do
  @moduledoc """
  The last of the four kinds #2015 moves into the shared `images` table
  (issue #2055): the cover of a book review is a row there beside the review
  row it has always lived on, kept in step by every write, and nothing about
  how it is stored or served has moved.

  **It is not the shape the other three took.** A post photo, an organization
  image and a job-posting picture each have a row of their own carrying a
  `token`, so they join the mirror on that token. A review's cover is
  `cover` / `cover_status` / `cover_moderation` *columns on the review row*
  with no token and no table — the profile picture's shape — so it joins on a
  parent column (`images.post_review_id`) and the token is minted here.

  **And nobody uploaded it.** The cover is fetched from Open Library, so there
  is no member who owns it: `images.user_id` means a member owner and cascades
  on delete, and the reviewer is not the owner of a publisher's picture. The
  post carrying the review may not even have a member author — an organization
  publishes reviews too, and `posts.user_id` is NULL for those — so the owner
  is the review, under a check constraint rather than a comment.

  Not async: the fetch writes files, so the module holds the global
  `:uploads_dir_prefix` down for its lifetime.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Images
  alias Vutuv.Images.Image, as: ImageRow
  alias Vutuv.Moderation.ImageScan
  alias Vutuv.Moderation.ImageSubjects
  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Posts.PostReview
  alias Vutuv.Posts.ReviewCovers
  alias Vutuv.Repo
  alias Vutuv.ReviewCover

  @kind "review_cover"
  @isbn "9783161484100"
  @other_isbn "9780262033848"

  defp review_attrs(isbn), do: %{kind: "book", identifier: isbn, title: "Refactoring"}

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "vutuv_review_covers_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, tmp: tmp}
  end

  # Real JPEG bytes (synthesized via libvips), so the decode succeeds and a
  # file really lands on disk — "the cover is stored" is a claim about bytes.
  defp jpeg_bytes(color) do
    {:ok, img} = Image.new(120, 180, color: color)
    {:ok, bytes} = Image.write(img, :memory, suffix: ".jpg")
    bytes
  end

  # Open Library answering with a cover, then the fetch the request path runs.
  defp fetch!(review, color \\ [10, 120, 200]) do
    Application.put_env(:vutuv, :book_covers_req_options,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/jpeg")
        |> Plug.Conn.resp(200, jpeg_bytes(color))
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :book_covers_req_options) end)

    :ok = ReviewCovers.fetch(review)
    Repo.get!(PostReview, review.id)
  end

  defp mirror(review), do: Vutuv.ImageHelpers.review_cover_row(review)

  describe "the row beside the review row" do
    test "a fetched cover writes one, column for column" do
      review = insert(:post_review, cover_status: "pending")
      stored = fetch!(review)

      assert %ImageRow{} = row = mirror(stored)
      assert row.kind == @kind
      assert row.post_review_id == review.id
      assert row.file == stored.cover
      assert row.moderation == stored.cover_moderation
      assert row.frozen_at == nil
      # Minted here: the review row has no handle of its own to repeat.
      assert is_binary(row.token) and row.token != ""
    end

    # The picture is a publisher's, fetched from a catalogue. `images.user_id`
    # means a member *owner* and cascades on delete, so naming the reviewer
    # there would arm a deletion on a picture that is not theirs.
    test "the reviewer is not its owner" do
      review = insert(:post_review, cover_status: "pending")

      assert %ImageRow{user_id: nil} = mirror(fetch!(review))
    end

    # The case that decides the owner column: a page publishes a review, the
    # post has NO member author at all (`posts.user_id` is NULL beside
    # `organization_id`), and a row keyed on a member owner could not exist.
    test "a review published in an organization's name gets its row too" do
      put_config(:verify_organization_domains, true)
      on_exit(fn -> Application.delete_env(:vutuv, :organizations_dns_resolver) end)

      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

      {:ok, post} =
        Posts.create_organization_post(organization, owner, %{
          body: "Gelesen",
          review: review_attrs(@isbn)
        })

      assert post.user_id == nil
      stored = fetch!(post.review)

      assert %ImageRow{user_id: nil, post_review_id: review_id} = mirror(stored)
      assert review_id == post.review.id

      # And the fetch really finished. Announcing the cover fans out to the
      # author's followers, which for a page hangs off
      # `followee_organization_id` — handing the nil author to the member
      # query raised, `fetch/1`'s own rescue swallowed it, and the review was
      # written off as `failed` with its picture already on disk.
      assert stored.cover_status == "ready"
    end

    test "a re-fetch replaces the row and mints a fresh token" do
      review = insert(:post_review, cover_status: "pending")
      first = fetch!(review)
      first_row = mirror(first)

      second = fetch!(first, [200, 30, 30])
      second_row = mirror(second)

      assert second.cover != first.cover
      assert second_row.id == first_row.id
      assert second_row.file == second.cover
      # A token names the bytes, so a report that named the old cover points
      # at nothing rather than quietly at the new one.
      assert second_row.token != first_row.token
    end

    test "the same bytes again keep the token they had" do
      review = insert(:post_review, cover_status: "pending")
      first = fetch!(review)
      first_row = mirror(first)

      second = fetch!(first)

      assert second.cover == first.cover
      assert mirror(second).token == first_row.token
    end
  end

  describe "every path that touches the cover keeps the row in step" do
    setup do
      put_config(:moderate_images, true)
      :ok
    end

    test "the AI gate's release reaches the row" do
      review = insert(:post_review, cover_status: "pending")
      stored = fetch!(review)

      assert stored.cover_moderation == "pending"
      assert mirror(stored).moderation == "pending"

      scan = Repo.get_by!(ImageScan, kind: @kind, subject_id: review.id)
      assert :ok = ImageSubjects.apply_approved(scan)

      assert mirror(stored).moderation == "approved"
      assert Repo.get!(PostReview, review.id).cover_moderation == "approved"
    end

    test "a rejected cover takes its row with it" do
      review = insert(:post_review, cover_status: "pending")
      stored = fetch!(review)
      assert mirror(stored)

      scan = Repo.get_by!(ImageScan, kind: @kind, subject_id: review.id)
      assert :ok = ImageSubjects.apply_rejected(scan)

      assert Repo.get!(PostReview, review.id).cover == nil
      assert mirror(stored) == nil
    end
  end

  describe "the row follows the review row" do
    setup do
      author = insert(:activated_user)

      {:ok, post} =
        Posts.create_post(author, %{body: "Gelesen", review: review_attrs(@isbn)})

      stored = fetch!(post.review)
      assert mirror(stored)

      {:ok, post: post, stored: stored}
    end

    test "changing the reviewed ISBN drops the cover and its row", ctx do
      # Re-read the way the editor does: the struct `create_post/2` handed
      # back predates the fetch, and `change(cover: nil)` on a review that
      # already reads nil records nothing at all.
      post = Repo.preload(ctx.post, :review, force: true)

      {:ok, updated} =
        Posts.update_post(post, %{body: "Gelesen", review: review_attrs(@other_isbn)})

      assert updated.review.cover == nil
      assert mirror(ctx.stored) == nil
    end

    # The other half of that: an editor holding a stale review (its cover
    # fetched after the page was loaded) must not take the row of a picture
    # that is still there — the mirror follows the row, not the struct.
    test "an edit that keeps the cover keeps its row", ctx do
      row = mirror(ctx.stored)

      {:ok, _updated} =
        Posts.update_post(ctx.post, %{body: "Immer noch gelesen", review: review_attrs(@isbn)})

      assert Repo.get!(PostReview, ctx.stored.id).cover == ctx.stored.cover
      assert mirror(ctx.stored).id == row.id
    end

    test "deleting the post takes the row with it", ctx do
      {:ok, _} = Posts.delete_post(ctx.post)

      assert Repo.aggregate(from(i in ImageRow, where: i.kind == ^@kind), :count) == 0
    end
  end

  # `mirror/2` and the sync below write through `insert_all`, so no changeset
  # stands between a future author and the shape. The database holds it.
  describe "the shape the database holds" do
    test "a review cover with a member owner is refused" do
      review = insert(:post_review)
      user = insert(:activated_user)

      assert_raise Ecto.ConstraintError, ~r/images_review_kind_owned_by_review/, fn ->
        Repo.insert!(%ImageRow{
          kind: @kind,
          token: "t-#{System.unique_integer([:positive])}",
          post_review_id: review.id,
          user_id: user.id
        })
      end
    end

    test "a review cover naming no review is refused" do
      assert_raise Ecto.ConstraintError, ~r/images_review_kind_owned_by_review/, fn ->
        Repo.insert!(%ImageRow{
          kind: @kind,
          token: "t-#{System.unique_integer([:positive])}"
        })
      end
    end

    test "one review has at most one cover row" do
      review = insert(:post_review)

      Repo.insert!(%ImageRow{
        kind: @kind,
        token: "t-#{System.unique_integer([:positive])}",
        post_review_id: review.id
      })

      assert_raise Ecto.ConstraintError, ~r/images_post_review_id_index/, fn ->
        Repo.insert!(%ImageRow{
          kind: @kind,
          token: "t-#{System.unique_integer([:positive])}",
          post_review_id: review.id
        })
      end
    end
  end

  describe "nothing about the picture itself has moved" do
    test "the URL and the file on disk are the ones they were" do
      review = insert(:post_review, cover_status: "pending")
      stored = fetch!(review)

      version = ReviewCover.version_name(stored)
      assert version == "cover-" <> Path.rootname(stored.cover)
      assert ReviewCover.url(stored) == "/review_covers/#{stored.id}/#{version}.avif"
      assert ReviewCover.version_path(stored, version)
    end

    # The expand half writes the row and reads nothing from it, so a report
    # cannot name one of these pictures yet: the case's uphold would reach a
    # freeze with no strategy for the kind and raise in front of the admin.
    test "the takedown gate still refuses this kind" do
      refute Images.takedown_ready?(%ImageRow{kind: @kind})

      assert_raise ArgumentError, ~r/nothing here can take a picture of that kind/, fn ->
        Images.freeze(%ImageRow{kind: @kind})
      end
    end

    test "and it is served through its authorizing proxy, like the other three" do
      assert Images.serving(@kind) == :proxy
      assert @kind in Images.kinds()
    end
  end
end
