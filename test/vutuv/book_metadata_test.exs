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
    Application.put_env(:vutuv, :book_metadata_req_options,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end
    )
  end

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
