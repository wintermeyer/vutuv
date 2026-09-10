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
