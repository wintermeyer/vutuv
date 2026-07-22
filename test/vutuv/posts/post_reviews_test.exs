defmodule Vutuv.Posts.PostReviewsTest do
  @moduledoc """
  The review sidecar through the Posts context: create/update/delete a post
  with review attrs, the partial-update semantics (no :review key = leave it
  alone), and the cover fetch pipeline with stubbed HTTP.
  """

  use Vutuv.DataCase, async: true

  import Vutuv.Factory

  alias Vutuv.Posts
  alias Vutuv.Posts.PostReview
  alias Vutuv.Posts.ReviewCovers
  alias Vutuv.Repo
  alias Vutuv.Uploads.Originals

  @book_review %{
    "kind" => "book",
    "identifier" => "978-3-16-148410-0",
    "title" => "Refactoring",
    "creator" => "Martin Fowler",
    "year" => "2018"
  }

  describe "create_post/2 with a review" do
    test "persists the review beside the post" do
      author = insert(:user)

      assert {:ok, post} =
               Posts.create_post(author, %{body: "Lesenswert!", review: @book_review})

      assert %PostReview{} = post.review
      assert post.review.kind == "book"
      assert post.review.identifier == "9783161484100"
      assert post.review.title == "Refactoring"
      assert post.review.year == 2018
      assert post.review.cover_status == "pending"
    end

    test "a movie review stores the IMDb id and fetches no cover" do
      author = insert(:user)

      assert {:ok, post} =
               Posts.create_post(author, %{
                 body: "Starker Film.",
                 review: %{
                   "kind" => "movie",
                   "identifier" => "https://www.imdb.com/title/tt0111161/",
                   "title" => "Die Verurteilten",
                   "creator" => "Frank Darabont",
                   "year" => "1994"
                 }
               })

      assert post.review.kind == "movie"
      assert post.review.identifier == "tt0111161"
      assert post.review.cover_status == "none"
    end

    test "a blank kind or a missing review key creates no review" do
      author = insert(:user)

      assert {:ok, post} = Posts.create_post(author, %{body: "Ohne Review"})
      assert post.review == nil

      assert {:ok, post} =
               Posts.create_post(author, %{body: "Auch ohne", review: %{"kind" => ""}})

      assert post.review == nil
    end

    test "an invalid review rejects the whole post" do
      author = insert(:user)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Posts.create_post(author, %{
                 body: "Kaputt",
                 review: %{"kind" => "book", "identifier" => "not-an-isbn", "title" => "X"}
               })

      assert %{review: %{identifier: [_message]}} = errors_on(changeset)
    end
  end

  describe "update_post/2 and the review" do
    test "adds a review to an existing post" do
      post = insert(:post)

      assert {:ok, updated} = Posts.update_post(post, %{body: post.body, review: @book_review})
      assert updated.review.title == "Refactoring"
    end

    test "a blank kind removes the review" do
      review = insert(:post_review)

      assert {:ok, updated} =
               Posts.update_post(review.post, %{body: "bleibt", review: %{"kind" => ""}})

      assert updated.review == nil
      assert Repo.get(PostReview, review.id) == nil
    end

    test "attrs without a :review key leave the review untouched (partial update)" do
      review = insert(:post_review)

      assert {:ok, updated} = Posts.update_post(review.post, %{body: "nur der Text"})

      assert updated.review.id == review.id
      assert updated.review.title == review.title
    end

    test "a changed ISBN resets the cover to pending" do
      review =
        insert(:post_review,
          cover: "abcdef123456.jpg",
          cover_status: "ready",
          cover_moderation: "approved"
        )

      assert {:ok, updated} =
               Posts.update_post(review.post, %{
                 body: "neues Buch",
                 review: %{"kind" => "book", "identifier" => "9780306406157", "title" => "Anders"}
               })

      assert updated.review.id == review.id
      assert updated.review.identifier == "9780306406157"
      assert updated.review.cover == nil
      assert updated.review.cover_status == "pending"
    end
  end

  test "delete_post/1 removes the review row" do
    review = insert(:post_review)

    assert {:ok, _} = Posts.delete_post(review.post)
    assert Repo.get(PostReview, review.id) == nil
  end

  describe "ReviewCovers.fetch/1" do
    # Real JPEG bytes (synthesized via libvips), so the decode succeeds.
    defp jpeg_bytes do
      path =
        Path.join(System.tmp_dir!(), "review_cover_src_#{System.unique_integer([:positive])}.jpg")

      {:ok, img} = Image.new(120, 180, color: [10, 120, 200])
      {:ok, _} = Image.write(img, path)
      bytes = File.read!(path)
      File.rm(path)
      bytes
    end

    defp fetch_with_status(review, status, body \\ "") do
      Application.put_env(:vutuv, :book_covers_req_options,
        plug: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("image/jpeg")
          |> Plug.Conn.resp(status, body)
        end
      )

      on_exit(fn -> Application.delete_env(:vutuv, :book_covers_req_options) end)

      ReviewCovers.fetch(review)
    end

    test "stores the cover and marks the review ready" do
      review = insert(:post_review, cover_status: "pending")

      assert :ok = fetch_with_status(review, 200, jpeg_bytes())

      stored = Repo.get(PostReview, review.id)
      assert stored.cover_status == "ready"
      assert is_binary(stored.cover)
      # :moderate_images is off in tests, so the cover is born released.
      assert PostReview.cover_ready?(stored)

      assert Vutuv.ReviewCover.version_path(stored, Vutuv.ReviewCover.version_name(stored))
      Vutuv.ReviewCover.delete_files(stored)
    end

    # The edition details ride on the same fetch as the cover, so an
    # installation with the flag off gets neither. `edition` is Open
    # Library's edition record, `extent` the catalogue's MARC 300 field.
    defp stub_details(edition, extent \\ nil) do
      Application.put_env(:vutuv, :fetch_book_metadata, true)

      Application.put_env(:vutuv, :book_metadata_req_options,
        plug: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(edition))
        end
      )

      if extent do
        Application.put_env(:vutuv, :dnb_req_options,
          plug: fn conn ->
            xml = """
            <searchRetrieveResponse><records><record><recordData><record>
              <datafield tag="300"><subfield code="a">#{extent}</subfield></datafield>
            </record></recordData></record></records></searchRetrieveResponse>
            """

            Plug.Conn.resp(conn, 200, xml)
          end
        )
      end

      on_exit(fn ->
        Application.put_env(:vutuv, :fetch_book_metadata, false)
        Application.delete_env(:vutuv, :book_metadata_req_options)
        Application.delete_env(:vutuv, :dnb_req_options)
      end)
    end

    test "stores the edition details Open Library knows" do
      review = insert(:post_review, cover_status: "pending")
      stub_details(%{"number_of_pages" => 448, "publishers" => ["Addison-Wesley"]})

      assert :ok = fetch_with_status(review, 404)

      stored = Repo.get(PostReview, review.id)
      assert stored.pages == 448
      assert stored.publisher == "Addison-Wesley"
      # A missing cover costs the card its picture, never its facts.
      assert stored.cover_status == "failed"
    end

    test "an audiobook review also stores its running time" do
      review = insert(:post_review, cover_status: "pending", medium: "audiobook")
      stub_details(%{"number_of_pages" => 190}, "Online-Ressource 75 Min.")

      assert :ok = fetch_with_status(review, 404)

      stored = Repo.get(PostReview, review.id)
      assert stored.duration_minutes == 75
      # The page count is the book's, and it shows on the audiobook card too.
      assert stored.pages == 190
    end

    test "a print review asks no catalogue for a running time" do
      review = insert(:post_review, cover_status: "pending", medium: "print")
      stub_details(%{"number_of_pages" => 190})

      # No :dnb_req_options stub at all: a request would hit the network and
      # the test would fail on it, which is the assertion.
      assert :ok = fetch_with_status(review, 404)

      assert Repo.get(PostReview, review.id).duration_minutes == nil
    end

    test "a changed ISBN drops the details of the previous edition" do
      review =
        insert(:post_review,
          cover_status: "ready",
          pages: 448,
          publisher: "Goldmann",
          duration_minutes: 75
        )

      assert {:ok, updated} =
               Posts.update_post(review.post, %{
                 body: "andere Ausgabe",
                 review: %{"kind" => "book", "identifier" => "9780306406157", "title" => "Anders"}
               })

      assert updated.review.pages == nil
      assert updated.review.publisher == nil
      assert updated.review.duration_minutes == nil
      assert updated.review.cover_status == "pending"
    end

    test "keeps no private original of the fetched cover" do
      review = insert(:post_review, cover_status: "pending")

      assert :ok = fetch_with_status(review, 200, jpeg_bytes())

      stored = Repo.get(PostReview, review.id)
      # A cover is somebody else's picture quoted at thumbnail size: we keep
      # the one derived version we show and nothing beyond it. Re-deriving
      # after a Spec change re-fetches by ISBN instead (refresh_all/1).
      assert Originals.path("review_covers/#{review.id}") == nil

      Vutuv.ReviewCover.delete_files(stored)
    end

    test "refresh_all/1 re-fetches every stored cover and purges legacy originals" do
      review = insert(:post_review, cover_status: "pending")
      assert :ok = fetch_with_status(review, 200, jpeg_bytes())

      # A cover stored before v7.122.4 left a full-resolution original behind.
      legacy = Path.join(System.tmp_dir!(), "legacy_original_#{review.id}.jpg")
      File.write!(legacy, jpeg_bytes())
      :ok = Originals.store("review_covers/#{review.id}", legacy, ".jpg")
      File.rm(legacy)
      assert Originals.path("review_covers/#{review.id}")

      stored = Repo.get(PostReview, review.id)
      previous = stored.cover

      # refresh_all/1 honours the fetch flag (an air-gapped install stays
      # air-gapped), which the test env keeps off.
      Application.put_env(:vutuv, :fetch_book_metadata, true)
      on_exit(fn -> Application.put_env(:vutuv, :fetch_book_metadata, false) end)

      Application.put_env(:vutuv, :book_covers_req_options,
        plug: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("image/jpeg")
          |> Plug.Conn.resp(200, jpeg_bytes())
        end
      )

      on_exit(fn -> Application.delete_env(:vutuv, :book_covers_req_options) end)

      assert %{refetched: 1} = ReviewCovers.refresh_all(delay: 0)

      refreshed = Repo.get(PostReview, review.id)
      assert refreshed.cover_status == "ready"
      assert is_binary(refreshed.cover)
      assert previous != nil
      assert Originals.path("review_covers/#{review.id}") == nil

      Vutuv.ReviewCover.delete_files(refreshed)
    end

    test "a 404 (no cover known) marks the fetch failed" do
      review = insert(:post_review, cover_status: "pending")

      fetch_with_status(review, 404)

      assert Repo.get(PostReview, review.id).cover_status == "failed"
    end

    test "undecodable bytes mark the fetch failed" do
      review = insert(:post_review, cover_status: "pending")

      fetch_with_status(review, 200, "definitely not a jpeg")

      assert Repo.get(PostReview, review.id).cover_status == "failed"
    end
  end
end
