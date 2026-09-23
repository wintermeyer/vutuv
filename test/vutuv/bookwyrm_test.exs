defmodule Vutuv.BookwyrmTest do
  # Not async: the Req seam and the SSRF resolver live in the application env.
  use Vutuv.DataCase

  alias Vutuv.Bookwyrm
  alias Vutuv.SocialFeed.Book
  alias Vutuv.SocialFeed.Feed
  alias Vutuv.SocialFeed.Post

  @handle "alice@books.example"
  @base "https://books.example"
  @actor "#{@base}/user/alice"
  @cover_bytes <<255, 216, 255, 224, 0, 16, 74, 70, 73, 70>>

  defp stub_bookwyrm(fun) do
    Application.put_env(:vutuv, :bookwyrm_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :bookwyrm_req_options) end)
  end

  # A BookWyrm server with one actor, its outbox and whatever `items` the first
  # outbox page lists. `books` maps a path (`/book/1`) to its Edition document;
  # every request is reported back as `{:req, path}`.
  defp serve(items, opts \\ []) do
    test_pid = self()
    books = Keyword.get(opts, :books, %{"/book/1" => edition()})

    stub_bookwyrm(fn conn ->
      send(test_pid, {:req, conn.request_path})
      respond(conn, {conn.request_path, conn.query_string}, items, books)
    end)
  end

  defp respond(conn, {"/.well-known/webfinger", "resource=acct%3Aalice%40books.example"}, _, _) do
    json_resp(conn, %{
      "subject" => "acct:#{@handle}",
      "links" => [%{"rel" => "self", "type" => "application/activity+json", "href" => @actor}]
    })
  end

  defp respond(conn, {"/user/alice", _}, _, _) do
    json_resp(conn, %{
      "id" => @actor,
      "type" => "Person",
      "name" => "Alice Liest",
      "outbox" => "#{@actor}/outbox"
    })
  end

  defp respond(conn, {"/user/alice/outbox", ""}, items, _) do
    json_resp(conn, %{
      "type" => "OrderedCollection",
      "totalItems" => length(items),
      "first" => "#{@actor}/outbox?page=1"
    })
  end

  defp respond(conn, {"/user/alice/outbox", "page=1"}, items, _),
    do: json_resp(conn, %{"type" => "OrderedCollectionPage", "orderedItems" => items})

  defp respond(conn, {"/author/7", _}, _, _),
    do: json_resp(conn, %{"id" => "#{@base}/author/7", "type" => "Author", "name" => "Wolf Haas"})

  defp respond(conn, {"/images/covers/1.jpg", _}, _, _) do
    conn
    |> Plug.Conn.put_resp_content_type("image/jpeg")
    |> Plug.Conn.send_resp(200, @cover_bytes)
  end

  defp respond(conn, {path, _}, _, books) do
    case Map.fetch(books, path) do
      {:ok, :fail} -> Plug.Conn.send_resp(conn, 500, "boom")
      {:ok, doc} -> json_resp(conn, doc)
      :error -> Plug.Conn.send_resp(conn, 404, "")
    end
  end

  # BookWyrm answers `application/activity+json`; the client decodes the body
  # itself, so the stub must carry the real content type (see the Mastodon test).
  defp json_resp(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/activity+json")
    |> Plug.Conn.send_resp(200, Jason.encode!(payload))
  end

  defp edition(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "#{@base}/book/1",
        "type" => "Edition",
        "title" => "Wackelkontakt",
        "authors" => ["#{@base}/author/7"],
        "cover" => %{"type" => "Image", "url" => "#{@base}/images/covers/1.jpg"}
      },
      attrs
    )
  end

  defp review(attrs) do
    Map.merge(
      %{
        "id" => "#{@actor}/review/1",
        "type" => "Article",
        "published" => "2026-06-08T14:42:01.873937+00:00",
        "attributedTo" => @actor,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "<p>Ein gro&szlig;er <b>Lesespa&szlig;</b>.</p>",
        "name" => ~s(Rezension von "Wackelkontakt" \(5 Sterne\): Verwobene Schicksale),
        "rating" => 5.0,
        "inReplyToBook" => "#{@base}/book/1",
        "sensitive" => false
      },
      attrs
    )
  end

  defp note(id) do
    %{
      "id" => "#{@actor}/generatednote/#{id}",
      "type" => "Note",
      "published" => "2026-06-08T14:49:07+00:00",
      "attributedTo" => @actor,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "content" => "<p>hat Wackelkontakt fertig gelesen</p>"
    }
  end

  defp override_resolver(fun) do
    original = Application.get_env(:vutuv, :ssrf_resolver)
    Application.put_env(:vutuv, :ssrf_resolver, fun)
    on_exit(fn -> Application.put_env(:vutuv, :ssrf_resolver, original) end)
  end

  describe "fetch_posts/1" do
    test "keeps the reviews, with the book they are about" do
      serve([note(9), review(%{})])

      assert {:ok, %Feed{} = feed} = Bookwyrm.fetch_posts(@handle)
      assert feed.name == "Alice Liest"
      assert feed.handle == @handle
      assert feed.url == @actor

      assert [%Post{} = post] = feed.posts
      assert post.url == "#{@actor}/review/1"
      assert post.text == "Ein großer Lesespaß."
      assert post.created_at == ~U[2026-06-08 14:42:01.873937Z]

      assert %Book{} = book = post.book
      assert book.title == "Wackelkontakt"
      assert book.author == "Wolf Haas"
      assert book.rating == 5.0
      assert book.headline == "Verwobene Schicksale"
      # Fetched server-side, so no visitor's browser contacts the instance.
      assert "data:image/jpeg;base64," <> _ = book.cover
    end

    test "reads the headline from an English name and a review without stars" do
      serve([
        review(%{
          "name" => ~s(Review of "Wackelkontakt": Great fun),
          "rating" => nil
        })
      ])

      assert {:ok, %Feed{posts: [post]}} = Bookwyrm.fetch_posts(@handle)
      assert post.book.headline == "Great fun"
      assert post.book.rating == nil
    end

    test "a book that cannot be fetched still shows the review under its quoted title" do
      serve([review(%{})], books: %{"/book/1" => :fail})

      assert {:ok, %Feed{posts: [post]}} = Bookwyrm.fetch_posts(@handle)
      assert post.book.title == "Wackelkontakt"
      assert post.book.headline == "Verwobene Schicksale"
      assert post.book.author == nil
      assert post.book.cover == nil
    end

    test "shows at most three reviews, newest first as the outbox lists them" do
      reviews =
        for n <- 1..5 do
          review(%{
            "id" => "#{@actor}/review/#{n}",
            "name" => ~s(Review of "Wackelkontakt": No. #{n})
          })
        end

      serve(reviews)

      assert {:ok, %Feed{posts: posts}} = Bookwyrm.fetch_posts(@handle)
      assert Enum.map(posts, & &1.book.headline) == ["No. 1", "No. 2", "No. 3"]
    end

    test "skips a review that is not public or not by this account" do
      serve([
        review(%{"id" => "#{@actor}/review/1", "to" => ["#{@actor}/followers"]}),
        review(%{"id" => "#{@actor}/review/2", "attributedTo" => "#{@base}/user/mallory"})
      ])

      assert {:ok, %Feed{posts: []}} = Bookwyrm.fetch_posts(@handle)
    end

    test "a content warning replaces the review text" do
      serve([review(%{"sensitive" => true, "summary" => "Spoiler zum Ende"})])

      assert {:ok, %Feed{posts: [post]}} = Bookwyrm.fetch_posts(@handle)
      assert post.text == "Spoiler zum Ende"
    end

    test "an unknown account is gone, a failing server is transient" do
      stub_bookwyrm(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
      assert {:error, :gone} = Bookwyrm.fetch_posts(@handle)

      stub_bookwyrm(fn conn -> Plug.Conn.send_resp(conn, 500, "") end)
      assert {:error, :transient} = Bookwyrm.fetch_posts(@handle)
    end

    test "a malformed handle or an instance on our own network is gone, unasked" do
      stub_bookwyrm(fn conn -> flunk("unexpected request to #{conn.request_path}") end)

      assert {:error, :gone} = Bookwyrm.fetch_posts("no-instance")
      assert {:error, :gone} = Bookwyrm.fetch_posts("alice@books.example:8080")

      override_resolver(fn _host, _family -> {:ok, [{127, 0, 0, 1}]} end)
      assert {:error, :gone} = Bookwyrm.fetch_posts(@handle)
    end
  end
end
