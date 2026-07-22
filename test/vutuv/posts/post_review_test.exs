defmodule Vutuv.Posts.PostReviewTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Posts.PostReview

  defp changeset(params), do: PostReview.changeset(%PostReview{}, params)

  describe "changeset/2 — book" do
    test "normalizes the ISBN and queues the cover fetch" do
      changeset =
        changeset(%{
          "kind" => "book",
          "identifier" => "978-3-16-148410-0",
          "title" => "Beispielbuch",
          "creator" => "Erika Mustermann",
          "year" => "2021"
        })

      assert changeset.valid?
      assert get_change(changeset, :identifier) == "9783161484100"
      assert get_field(changeset, :cover_status) == "pending"
      assert get_field(changeset, :year) == 2021
    end

    test "an ISBN-10 is stored in its ISBN-13 form" do
      changeset =
        changeset(%{"kind" => "book", "identifier" => "3-16-148410-X", "title" => "Altes Buch"})

      assert get_change(changeset, :identifier) == "9783161484100"
    end

    test "a book without ISBN is fine and fetches no cover" do
      changeset = changeset(%{"kind" => "book", "title" => "Ohne ISBN"})

      assert changeset.valid?
      assert get_field(changeset, :cover_status) == "none"
    end

    test "an invalid ISBN is rejected" do
      changeset = changeset(%{"kind" => "book", "identifier" => "12345", "title" => "Kaputt"})

      refute changeset.valid?
      assert %{identifier: [_message]} = errors_on(changeset)
    end

    test "a changed ISBN resets a previously fetched cover" do
      existing = %PostReview{
        kind: "book",
        identifier: "9783161484100",
        title: "Buch",
        cover: "abcdef123456.jpg",
        cover_status: "ready",
        cover_moderation: "approved"
      }

      changeset = PostReview.changeset(existing, %{"identifier" => "9780306406157"})

      assert get_field(changeset, :cover) == nil
      assert get_field(changeset, :cover_status) == "pending"
      assert get_field(changeset, :cover_moderation) == nil
    end

    test "an unchanged ISBN leaves the cover state alone" do
      existing = %PostReview{
        kind: "book",
        identifier: "9783161484100",
        title: "Buch",
        cover: "abcdef123456.jpg",
        cover_status: "ready",
        cover_moderation: "approved"
      }

      changeset =
        PostReview.changeset(existing, %{"identifier" => "9783161484100", "year" => "1999"})

      assert changeset.valid?
      assert get_field(changeset, :cover) == "abcdef123456.jpg"
      assert get_field(changeset, :cover_status) == "ready"
    end
  end

  describe "changeset/2 — movie" do
    test "accepts a bare IMDb id" do
      changeset = changeset(%{"kind" => "movie", "identifier" => "tt0111161", "title" => "Film"})

      assert changeset.valid?
      assert get_change(changeset, :identifier) == "tt0111161"
      assert get_field(changeset, :cover_status) == "none"
    end

    test "extracts the id from a pasted IMDb URL" do
      changeset =
        changeset(%{
          "kind" => "movie",
          "identifier" => "https://www.imdb.com/title/tt0111161/?ref_=nv_sr_srsg_0",
          "title" => "Film"
        })

      assert get_change(changeset, :identifier) == "tt0111161"
    end

    test "rejects junk identifiers" do
      changeset = changeset(%{"kind" => "movie", "identifier" => "shawshank", "title" => "Film"})

      refute changeset.valid?
      assert %{identifier: [_message]} = errors_on(changeset)
    end
  end

  describe "changeset/2 — shared validations" do
    test "kind and title are required" do
      changeset = changeset(%{"kind" => "", "title" => ""})

      assert %{kind: [_], title: [_]} = errors_on(changeset)
    end

    test "unknown kinds are rejected" do
      changeset = changeset(%{"kind" => "hotel", "title" => "Grand Budapest"})

      assert %{kind: [_message]} = errors_on(changeset)
    end

    test "the year must be plausible" do
      assert %{year: [_]} =
               errors_on(changeset(%{"kind" => "book", "title" => "B", "year" => "999"}))

      assert %{year: [_]} =
               errors_on(changeset(%{"kind" => "book", "title" => "B", "year" => "3001"}))
    end

    test "the medium must fit the kind" do
      book = %{"kind" => "book", "title" => "B"}
      movie = %{"kind" => "movie", "title" => "F"}

      assert changeset(Map.put(book, "medium", "audiobook")).valid?
      assert changeset(Map.put(movie, "medium", "cinema")).valid?
      assert %{medium: [_]} = errors_on(changeset(Map.put(book, "medium", "cinema")))
      assert %{medium: [_]} = errors_on(changeset(Map.put(movie, "medium", "audiobook")))
      # The select's blank option stores nil.
      assert changeset(Map.put(book, "medium", "")) |> Ecto.Changeset.get_field(:medium) == nil
    end

    test "title and creator are capped at their column length" do
      too_long = String.duplicate("x", 256)

      assert %{title: [_], creator: [_]} =
               errors_on(
                 changeset(%{"kind" => "book", "title" => too_long, "creator" => too_long})
               )
    end
  end

  describe "link builders" do
    test "amazon_url/1 uses the ISBN-10 dp link for 978 ISBNs" do
      review = %PostReview{kind: "book", identifier: "9783161484100"}

      assert PostReview.amazon_url(review) == "https://www.amazon.de/dp/316148410X"
    end

    test "amazon_url/1 falls back to a search link for 979 ISBNs" do
      review = %PostReview{kind: "book", identifier: "9798765432105"}

      assert PostReview.amazon_url(review) == "https://www.amazon.de/s?k=9798765432105"
    end

    test "amazon_url/1 appends the configured affiliate tag" do
      review = %PostReview{kind: "book", identifier: "9783161484100"}

      Application.put_env(:vutuv, :amazon_affiliate_tag, "vutuv-21")
      on_exit(fn -> Application.delete_env(:vutuv, :amazon_affiliate_tag) end)

      assert PostReview.amazon_url(review) == "https://www.amazon.de/dp/316148410X?tag=vutuv-21"
    end

    test "amazon_url/1 is nil without an ISBN or with the shop switched off" do
      assert PostReview.amazon_url(%PostReview{kind: "book", identifier: nil}) == nil
      assert PostReview.amazon_url(%PostReview{kind: "movie", identifier: "tt0111161"}) == nil

      Application.put_env(:vutuv, :amazon_domain, "")
      on_exit(fn -> Application.delete_env(:vutuv, :amazon_domain) end)

      assert PostReview.amazon_url(%PostReview{kind: "book", identifier: "9783161484100"}) == nil
    end

    test "imdb_url/1 links the movie page" do
      review = %PostReview{kind: "movie", identifier: "tt0111161"}

      assert PostReview.imdb_url(review) == "https://www.imdb.com/title/tt0111161/"
      assert PostReview.imdb_url(%PostReview{kind: "movie", identifier: nil}) == nil
      assert PostReview.imdb_url(%PostReview{kind: "book", identifier: "9783161484100"}) == nil
    end
  end
end
