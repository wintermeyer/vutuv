defmodule Vutuv.FriendicaTest do
  # Not async: the Req seam and the SSRF resolver live in the application env.
  use Vutuv.DataCase

  alias Vutuv.Friendica
  alias Vutuv.SocialFeed.Feed
  alias Vutuv.SocialFeed.Post

  @handle "alice@friendica.example"
  @base "https://friendica.example"
  @actor "#{@base}/profile/alice"
  @public "https://www.w3.org/ns/activitystreams#Public"
  @avatar_bytes <<255, 216, 255, 224, 0, 16, 74, 70, 73, 70>>

  defp stub_friendica(fun) do
    Application.put_env(:vutuv, :friendica_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :friendica_req_options) end)
  end

  # A Friendica server shaped like friendica.opensocial.space answered on
  # 2026-09-23: the actor lives at /profile/<name> and carries no `icon`, the
  # avatar is named by WebFinger only, and the outbox wraps every note in its
  # Create. Every request is reported back as `{:req, path}`.
  defp serve(items, opts \\ []) do
    test_pid = self()
    followers = Keyword.get(opts, :followers, %{"totalItems" => 42})

    stub_friendica(fn conn ->
      send(test_pid, {:req, conn.request_path})
      respond(conn, {conn.request_path, conn.query_string}, items, followers)
    end)
  end

  defp respond(
         conn,
         {"/.well-known/webfinger", "resource=acct%3Aalice%40friendica.example"},
         _,
         _
       ) do
    json_resp(conn, %{
      "subject" => "acct:#{@handle}",
      "links" => [
        %{"rel" => "http://purl.org/macgirvin/dfrn/1.0", "href" => @actor},
        %{"rel" => "self", "type" => "application/activity+json", "href" => @actor},
        %{
          "rel" => "http://webfinger.net/rel/avatar",
          "type" => "image/jpeg",
          "href" => "#{@base}/photo/profile/alice.jpeg"
        }
      ]
    })
  end

  defp respond(conn, {"/profile/alice", _}, _, _) do
    json_resp(conn, %{
      "id" => @actor,
      "type" => "Person",
      "name" => "Alice Schreibt",
      "preferredUsername" => "alice",
      "url" => @actor,
      "outbox" => "#{@base}/outbox/alice",
      "followers" => "#{@base}/followers/alice"
    })
  end

  defp respond(conn, {"/outbox/alice", ""}, items, _) do
    json_resp(conn, %{
      "type" => "OrderedCollection",
      "totalItems" => length(items),
      "first" => "#{@base}/outbox/alice?page=1"
    })
  end

  defp respond(conn, {"/outbox/alice", "page=1"}, items, _),
    do: json_resp(conn, %{"type" => "OrderedCollectionPage", "orderedItems" => items})

  defp respond(conn, {"/followers/alice", _}, _, :fail), do: Plug.Conn.send_resp(conn, 500, "")

  defp respond(conn, {"/followers/alice", _}, _, followers),
    do: json_resp(conn, Map.put(followers, "type", "OrderedCollection"))

  defp respond(conn, {"/photo/profile/alice.jpeg", _}, _, _) do
    conn
    |> Plug.Conn.put_resp_content_type("image/jpeg")
    |> Plug.Conn.send_resp(200, @avatar_bytes)
  end

  defp respond(conn, _request, _, _), do: Plug.Conn.send_resp(conn, 404, "")

  # Friendica answers `application/activity+json`; the client decodes the body
  # itself, so the stub must carry the real content type (see the Mastodon test).
  defp json_resp(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/activity+json")
    |> Plug.Conn.send_resp(200, Jason.encode!(payload))
  end

  defp note_create(note_attrs) do
    note =
      Map.merge(
        %{
          "id" => "#{@base}/objects/1",
          "type" => "Note",
          "published" => "2026-09-23T07:36:20Z",
          # Friendica embeds the author's actor document, not its bare id.
          "attributedTo" => %{"id" => @actor, "type" => "Person"},
          "inReplyTo" => nil,
          "url" => "#{@base}/display/1",
          "to" => [@public],
          "cc" => ["#{@base}/followers/alice"],
          "sensitive" => false,
          "content" => "<p>Guten Morgen aus dem <b>Fediverse</b>.</p>"
        },
        note_attrs
      )

    %{"id" => note["id"] <> "/Create", "type" => "Create", "actor" => @actor, "object" => note}
  end

  defp override_resolver(fun) do
    original = Application.get_env(:vutuv, :ssrf_resolver)
    Application.put_env(:vutuv, :ssrf_resolver, fun)
    on_exit(fn -> Application.put_env(:vutuv, :ssrf_resolver, original) end)
  end

  describe "fetch_posts/1" do
    test "reads the public notes from the outbox, never the Mastodon lookup" do
      serve([note_create(%{})])

      assert {:ok, %Feed{} = feed} = Friendica.fetch_posts(@handle)
      assert feed.name == "Alice Schreibt"
      assert feed.handle == @handle
      assert feed.url == @actor
      assert feed.followers == 42
      # Named by WebFinger only, fetched server-side.
      assert "data:image/jpeg;base64," <> _ = feed.avatar

      assert [%Post{} = post] = feed.posts
      assert post.url == "#{@base}/display/1"
      assert post.text == "Guten Morgen aus dem Fediverse."
      assert post.created_at == ~U[2026-09-23 07:36:20Z]

      refute_received {:req, "/api/v1/accounts/lookup"}
    end

    test "shows at most three posts, newest first as the outbox lists them" do
      serve(
        for n <- 1..5 do
          note_create(%{"id" => "#{@base}/objects/#{n}", "content" => "<p>Nummer #{n}</p>"})
        end
      )

      assert {:ok, %Feed{posts: posts}} = Friendica.fetch_posts(@handle)
      assert Enum.map(posts, & &1.text) == ["Nummer 1", "Nummer 2", "Nummer 3"]
    end

    test "skips replies, boosts, non-public notes and notes by somebody else" do
      serve([
        note_create(%{
          "id" => "#{@base}/objects/1",
          "inReplyTo" => "https://elsewhere.example/1"
        }),
        %{"type" => "Announce", "actor" => @actor, "object" => "https://elsewhere.example/2"},
        note_create(%{
          "id" => "#{@base}/objects/3",
          "to" => ["#{@base}/followers/alice"],
          "cc" => []
        }),
        note_create(%{
          "id" => "#{@base}/objects/4",
          "attributedTo" => %{"id" => "#{@base}/profile/mallory"}
        }),
        note_create(%{"id" => "#{@base}/objects/5", "content" => "<p>Diese hier</p>"})
      ])

      assert {:ok, %Feed{posts: [post]}} = Friendica.fetch_posts(@handle)
      assert post.text == "Diese hier"
    end

    test "a post with a title arrives as an Article and leads with its title" do
      serve([
        note_create(%{
          "type" => "Article",
          "name" => "Karaoke in Wunstorf",
          "content" => "<p>Am 30.01.</p>"
        })
      ])

      assert {:ok, %Feed{posts: [post]}} = Friendica.fetch_posts(@handle)
      assert post.text == "Karaoke in Wunstorf\n\nAm 30.01."
    end

    test "a content warning replaces the text, sensitive media without one is dropped" do
      serve([
        note_create(%{"id" => "#{@base}/objects/1", "sensitive" => true}),
        note_create(%{"id" => "#{@base}/objects/2", "summary" => "Politik"})
      ])

      assert {:ok, %Feed{posts: [post]}} = Friendica.fetch_posts(@handle)
      assert post.text == "Politik"
    end

    test "a follower count the server will not give leaves the count nil, not the feed" do
      serve([note_create(%{})], followers: :fail)

      assert {:ok, %Feed{followers: nil, posts: [_]}} = Friendica.fetch_posts(@handle)
    end

    test "an unknown account is gone, a failing server is transient" do
      stub_friendica(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
      assert {:error, :gone} = Friendica.fetch_posts(@handle)

      stub_friendica(fn conn -> Plug.Conn.send_resp(conn, 500, "") end)
      assert {:error, :transient} = Friendica.fetch_posts(@handle)
    end

    test "a malformed handle or an instance on our own network is gone, unasked" do
      stub_friendica(fn conn -> flunk("unexpected request to #{conn.request_path}") end)

      assert {:error, :gone} = Friendica.fetch_posts("no-instance")
      assert {:error, :gone} = Friendica.fetch_posts("alice@friendica.example:8080")

      override_resolver(fn _host, _family -> {:ok, [{127, 0, 0, 1}]} end)
      assert {:error, :gone} = Friendica.fetch_posts(@handle)
    end
  end
end
