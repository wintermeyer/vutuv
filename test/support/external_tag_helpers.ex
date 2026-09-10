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
