defmodule Vutuv.BookMetadataTest do
  use ExUnit.Case, async: false

  alias Vutuv.BookMetadata

  @isbn "9783161484100"

  setup do
    Application.put_env(:vutuv, :fetch_book_metadata, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :fetch_book_metadata, false)
      Application.delete_env(:vutuv, :book_metadata_req_options)
    end)

    :ok
  end

  defp stub(body) do
    stub_by_path(fn _path -> body end)
  end

  # The edition lookup can make two requests (edition, then the work's other
  # editions), so the stub answers per path.
  defp stub_by_path(fun) do
    Application.put_env(:vutuv, :book_metadata_req_options,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(fun.(conn.request_path)))
      end
    )
  end

  describe "lookup/1 (the composer's prefill)" do
    test "parses title, authors and year from the Open Library answer" do
      stub(%{
        "ISBN:#{@isbn}" => %{
          "title" => "Refactoring",
          "authors" => [%{"name" => "Martin Fowler"}, %{"name" => "Kent Beck"}],
          "publish_date" => "November 2018"
        }
      })

      assert {:ok, %{title: "Refactoring", creator: "Martin Fowler, Kent Beck", year: 2018}} =
               BookMetadata.lookup(@isbn)
    end

    test "missing optional fields come back nil" do
      stub(%{"ISBN:#{@isbn}" => %{"title" => "Nur Titel"}})

      assert {:ok, %{title: "Nur Titel", creator: nil, year: nil}} = BookMetadata.lookup(@isbn)
    end

    test "an unknown ISBN is :error" do
      stub(%{})

      assert :error = BookMetadata.lookup(@isbn)
    end

    test "with the fetch flag off nothing is looked up" do
      Application.put_env(:vutuv, :fetch_book_metadata, false)
      stub(%{"ISBN:#{@isbn}" => %{"title" => "Nie geholt"}})

      assert :error = BookMetadata.lookup(@isbn)
    end
  end

  describe "edition_details/1" do
    test "reads page count and publisher from the edition record" do
      # The edition record — not the books API — is where Open Library keeps
      # `number_of_pages`, and it lists publishers as plain strings.
      stub(%{"number_of_pages" => 190, "publishers" => ["Goldmann", "Random House"]})

      assert {:ok, %{pages: 190, publisher: "Goldmann"}} = BookMetadata.edition_details(@isbn)
    end

    test "an edition without pages borrows the median count of the work's editions" do
      stub_by_path(fn
        "/isbn/" <> _rest ->
          %{"publishers" => ["Random House Audio"], "works" => [%{"key" => "/works/OL1W"}]}

        "/works/OL1W/editions.json" ->
          %{
            "entries" => [
              %{"number_of_pages" => 190},
              %{"number_of_pages" => 208},
              # An omnibus edition must not decide the count for everyone.
              %{"number_of_pages" => 960},
              %{"physical_format" => "Audio CD"}
            ]
          }
      end)

      # A reader asking how long a book is means the book, not the pressing —
      # so an audiobook edition still gets a page count, the median 208.
      assert {:ok, %{pages: 208, publisher: "Random House Audio"}} =
               BookMetadata.edition_details(@isbn)
    end

    test "no page count anywhere stays nil" do
      stub_by_path(fn
        "/isbn/" <> _rest -> %{"works" => [%{"key" => "/works/OL1W"}]}
        "/works/OL1W/editions.json" -> %{"entries" => [%{"physical_format" => "Audio CD"}]}
      end)

      assert {:ok, %{pages: nil, publisher: nil}} = BookMetadata.edition_details(@isbn)
    end

    test "an implausible page count is dropped rather than shown" do
      # Open Library is crowd-edited: a 0 or a six-digit page count is a data
      # slip, and the card would print it as fact.
      stub(%{"number_of_pages" => 0})
      assert {:ok, %{pages: nil}} = BookMetadata.edition_details(@isbn)

      stub(%{"number_of_pages" => 1_000_000})
      assert {:ok, %{pages: nil}} = BookMetadata.edition_details(@isbn)
    end

    test "with the fetch flag off nothing is looked up" do
      Application.put_env(:vutuv, :fetch_book_metadata, false)
      stub(%{"number_of_pages" => 190})

      assert :error = BookMetadata.edition_details(@isbn)
    end
  end
end
