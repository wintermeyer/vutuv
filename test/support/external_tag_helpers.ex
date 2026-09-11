defmodule Vutuv.ExternalTagHelpers do
  @moduledoc """
  What the followed-tag pull's tests need to stand a remote server up (issue
  #2126): a Mastodon REST status, and a stub that answers the tag timeline with
  a list of them.

  One home for the status shape, because two test files read the same entity and
  a field the real API renames must not get fixed in one of them and stay wrong
  in the other.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Sets an application env key for the test and restores it afterwards.

  Captured with `fetch_env/2` and restored in two cases apart: a naive
  `put_env(key, get_env(key))` writes a real `nil` back for a key that was
  absent, which then answers `nil` instead of a function's default for every
  later test in the run.
  """
  def put_config(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  @doc """
  Stubs the tag-timeline fetch with `statuses` and reports every request back to
  the calling test as `{:req, host, path, query_string, req_headers}`.

  The answer is content-typed `application/json` because a real server's is:
  `Req`'s decode step branches on exactly that header, so a stub without it
  hands the client a binary where the real API hands it a decoded map, and
  cannot catch the regression that broke every feed fetch for 18 days.
  """
  def stub_tag_timeline(statuses) do
    test_pid = self()

    put_config(:external_tag_req_options,
      plug: fn conn ->
        send(test_pid, {:req, conn.host, conn.request_path, conn.query_string, conn.req_headers})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(statuses))
      end
    )
  end

  @doc """
  Stubs whole servers for the tag-source panel (issue #2128): NodeInfo
  discovery, the NodeInfo document, Mastodon's instance document and the tag
  timeline, dispatched by the host each request names.

  `servers` is `%{host => attrs}`. A host not in the map answers `404` to
  everything, which is what an unreachable server looks like from here. `attrs`
  takes `:accounts`, `:active_month`, `:posts`, `:language`, `:node_name`,
  `:description`, `:timeline` (the status code the tag timeline answers — `422`
  is Mastodon's "this method requires an authenticated user"), and
  `:nodeinfo_href` for the one case worth standing up on purpose: a link
  document pointing at somebody else's server. `:nodeinfo_links` replaces that
  document's whole `links` array, for a stranger's document that is not shaped
  like one at all.

  For the trending row (#2129) it also takes `:trends` — a list of
  `{name, history}` pairs, newest day first, which becomes this server's
  `/api/v1/trends/tags` — and `:samples`, a `%{hashtag => [status]}` map the tag
  timeline answers from, so a test can give one tag a bot farm and another a
  crowd. `:trends_status` makes the trending endpoint answer something other
  than `200`.

  The request is **dialled at the vetted IP**, so `conn.host` is that address on
  every call — the hostname is in the `host` header, which is what the dispatch
  and the `{:req, host, path}` report both read.
  """
  def stub_servers(servers) when is_map(servers) do
    test_pid = self()

    put_config(:external_tag_req_options,
      plug: fn conn ->
        host = header(conn, "host")
        send(test_pid, {:req, host, conn.request_path})
        answer(conn, host, Map.get(servers, host))
      end
    )
  end

  defp header(conn, name) do
    Enum.find_value(conn.req_headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  defp answer(conn, _host, nil), do: Plug.Conn.send_resp(conn, 404, "")

  defp answer(conn, host, attrs) do
    attrs = Map.new(attrs)

    case conn.request_path do
      "/.well-known/nodeinfo" ->
        json(conn, 200, %{"links" => Map.get(attrs, :nodeinfo_links, links(host, attrs))})

      "/nodeinfo/2.0" ->
        json(conn, 200, node_info(attrs))

      "/api/v2/instance" ->
        json(conn, 200, %{"languages" => List.wrap(Map.get(attrs, :language, "de"))})

      "/api/v1/trends/tags" ->
        json(conn, Map.get(attrs, :trends_status, 200), trends(attrs))

      "/api/v1/timelines/tag/" <> hashtag ->
        json(conn, Map.get(attrs, :timeline, 200), sample(attrs, hashtag))

      _other ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end

  # The Mastodon `Tag` entity as the trends endpoint serves it: seven days,
  # newest first, with `uses` and `accounts` as **strings** — which is how the
  # real API answers and the one detail a hand-rolled fixture gets wrong.
  defp trends(attrs) do
    attrs
    |> Map.get(:trends, [])
    |> Enum.map(fn {name, history} ->
      %{
        "name" => name,
        "url" => "https://example.test/tags/#{name}",
        "history" =>
          Enum.map(history, fn uses ->
            %{"day" => "1788998400", "uses" => to_string(uses), "accounts" => to_string(uses)}
          end)
      }
    end)
  end

  defp sample(attrs, hashtag) do
    attrs |> Map.get(:samples, %{}) |> Map.get(hashtag, [])
  end

  @doc """
  A trending tag's vetting sample: `count` statuses whose authors are spread
  over `hosts`, `bots` of them flagged as bot accounts by their own server.

  That is exactly the pair of facts the offer is judged on, and both come from
  the account the status carries rather than from anything we work out.
  """
  def sample_statuses(source, count, hosts, bots \\ 0) do
    hosts = List.wrap(hosts)

    Enum.map(0..(count - 1), fn index ->
      host = Enum.at(hosts, rem(index, length(hosts)))

      remote_status(source, %{
        "id" => "s#{index}",
        "account" => %{
          "acct" => "ada#{index}@#{host}",
          "display_name" => "Ada #{index}",
          "url" => "https://#{host}/@ada#{index}",
          "bot" => index < bots
        }
      })
    end)
  end

  defp links(host, attrs) do
    [
      %{
        "rel" => "http://nodeinfo.diaspora.software/ns/schema/2.0",
        "href" => Map.get(attrs, :nodeinfo_href, "https://#{host}/nodeinfo/2.0")
      }
    ]
  end

  defp node_info(attrs) do
    %{
      "version" => "2.0",
      "software" => %{"name" => "mastodon", "version" => "4.7.1"},
      "usage" => %{
        "users" => %{
          "total" => Map.get(attrs, :accounts, 49_157),
          "activeMonth" => Map.get(attrs, :active_month, 5_586)
        },
        "localPosts" => Map.get(attrs, :posts, 5_532_040)
      },
      "metadata" => %{
        "nodeName" => Map.get(attrs, :node_name, "Ein Server"),
        "nodeDescription" => Map.get(attrs, :description, "Hallo im Beispiel-Server!")
      }
    }
  end

  # The real APIs answer `application/json`, and Req's decode step branches on
  # exactly that header — a stub without it hands the client a binary where the
  # real server hands it a map.
  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  @doc "Stubs the fetch with a bare status code and body — no content type, as a broken server."
  def stub_tag_timeline_status(status, body \\ "") do
    put_config(:external_tag_req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, status, body) end
    )
  end

  @doc """
  The server a test's follow names, and the server the author of what it turns
  up actually lives on.

  Deliberately two different hostnames: the one thing these cards exist to get
  right is that the server we asked is not the author's home, so a fixture where
  they coincide would let a card that confused them pass.
  """
  def tag_source, do: "troet.example"
  def author_host, do: "mastodon.example"

  @doc """
  A member following `tag` through `source` — the follow this whole feature
  hangs off. `Vutuv.Tags.follow_tag/2` writes the local source itself; naming a
  server is what makes the pair wanted.
  """
  def follow_tag_through(user, tag, source \\ nil) do
    {:ok, follow} = Vutuv.Tags.follow_tag(user, tag)
    {:ok, _row} = Vutuv.Tags.add_tag_follow_source(follow, source || tag_source())
    follow
  end

  @doc """
  One already-cached external post, filed under `tag` — what the fetcher would
  have stored, without standing a server up for it.

  `source` defaults to the author's own host, which is the ordinary case only
  for a post the queried server's own member wrote; a test about the difference
  between the two passes both.
  """
  def external_post(tag, attrs \\ []) do
    attrs = Map.new(attrs)
    source = Map.get(attrs, :source, author_host())
    host = Map.get(attrs, :author_host, source)
    acct = if(host == source, do: "ada", else: "ada@#{host}")

    defaults = %{
      tag_id: tag.id,
      source: source,
      remote_id: "#{System.unique_integer([:positive])}",
      url: "https://#{host}/@ada/111",
      text: "Hello from over there",
      author_name: "Ada Lovelace",
      author_acct: acct,
      author_host: host,
      author_url: "https://#{host}/@ada",
      language: "de",
      published_at: DateTime.utc_now(:second)
    }

    Vutuv.Repo.insert!(struct!(Vutuv.Tags.ExternalPost, Map.merge(defaults, attrs)))
  end

  @doc """
  One Mastodon REST status, public, in German, with an author — merge `attrs`
  over it for the field a test is actually about.
  """
  def remote_status(source, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "#{System.unique_integer([:positive])}",
        "created_at" => "2026-08-01T10:30:00.000Z",
        "content" => "<p>Hello from over there</p>",
        "url" => "https://#{source}/@ada/111",
        "visibility" => "public",
        "language" => "de",
        "sensitive" => false,
        "spoiler_text" => "",
        "account" => %{
          "acct" => "ada",
          "display_name" => "Ada Lovelace",
          "url" => "https://#{source}/@ada"
        }
      },
      attrs
    )
  end
end
