defmodule Vutuv.Tags.ExternalTagClientTest do
  @moduledoc """
  The one outbound surface of issue #2126: reading a server's public tag
  timeline over its REST API, with the two guards the #2125 review left to the
  fetcher — the SSRF vet plus a pinned connection, and the operator's instance
  blocklist.

  `async: false`: it flips `:external_tag_req_options` (the Req seam),
  `:ssrf_resolver` (read by everything that vets an outbound host) and
  `:fetch_external_tag_posts`.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.ExternalTagHelpers

  alias Vutuv.Fediverse
  alias Vutuv.SocialFeed.Http
  alias Vutuv.Tags.ExternalTagClient

  @source "mastodon.example"

  # What `config/test.exs` resolves every hostname to, and therefore the address
  # a pinned request must be dialled at.
  @vetted_ip "93.184.216.34"

  setup do
    put_config(:fetch_external_tag_posts, true)
    :ok
  end

  defp status(attrs \\ %{}), do: remote_status(@source, attrs)

  describe "fetch/2" do
    test "asks the tag timeline and reduces a status to text and a link" do
      stub_tag_timeline([status(%{"id" => "111"})])

      assert {:ok, [post]} = ExternalTagClient.fetch(@source, "Machine Learning")

      assert_received {:req, host, path, query, headers}
      assert path == "/api/v1/timelines/tag/MachineLearning"
      assert query =~ "limit="

      # The request went to the vetted address, and still named the server it is
      # asking — and it introduced this installation rather than the HTTP
      # library, which a `headers:` override used to throw away.
      assert host == @vetted_ip
      assert {"host", @source} in headers
      assert {"user-agent", Http.user_agent()} in headers
      assert {"accept", "application/json"} in headers

      assert post.remote_id == "111"
      assert post.text == "Hello from over there"
      assert post.url == "https://#{@source}/@ada/111"
      assert post.language == "de"
      assert post.author_name == "Ada Lovelace"
      assert post.author_acct == "ada"
    end

    test "pins the connection to the vetted address instead of the hostname" do
      options = Http.pin(@source)

      assert options[:connect_options][:hostname] == @source
      assert {"host", @source} in options[:headers]

      stub_tag_timeline([status()])
      assert {:ok, _posts} = ExternalTagClient.fetch(@source, "Elixir")
      assert_received {:req, @vetted_ip, _path, _query, _headers}
    end

    test "refuses a host that resolves to an internal address" do
      put_config(:ssrf_resolver, fn _host, _family -> {:ok, [{127, 0, 0, 1}]} end)
      stub_tag_timeline([status()])

      assert ExternalTagClient.fetch(@source, "Elixir") == {:error, :internal}
      refute_received {:req, _host, _path, _query, _headers}
    end

    test "refuses a host that resolves to nothing" do
      put_config(:ssrf_resolver, fn _host, _family -> {:error, :nxdomain} end)
      stub_tag_timeline([status()])

      assert ExternalTagClient.fetch(@source, "Elixir") == {:error, :unresolvable}
      refute_received {:req, _host, _path, _query, _headers}
    end

    test "refuses a host the operator blocked, whenever they blocked it" do
      admin = insert(:activated_user)
      {:ok, {_blocked, _purged}} = Fediverse.block_instance(%{"host" => @source}, admin)
      stub_tag_timeline([status()])

      assert ExternalTagClient.fetch(@source, "Elixir") == {:error, :blocked}
      refute_received {:req, _host, _path, _query, _headers}
    end

    test "drops a status whose author lives on a blocked host" do
      admin = insert(:activated_user)
      {:ok, {_blocked, _purged}} = Fediverse.block_instance(%{"host" => "shouty.example"}, admin)

      stub_tag_timeline([
        status(%{"id" => "1", "account" => %{"acct" => "bob@shouty.example"}}),
        status(%{"id" => "2"})
      ])

      assert {:ok, [post]} = ExternalTagClient.fetch(@source, "Elixir")
      assert post.remote_id == "2"
    end

    test "skips a sensitive status and one behind a content warning" do
      stub_tag_timeline([
        status(%{"id" => "1", "sensitive" => true}),
        status(%{"id" => "2", "spoiler_text" => "Politik"}),
        status(%{"id" => "3"})
      ])

      assert {:ok, [post]} = ExternalTagClient.fetch(@source, "Elixir")
      assert post.remote_id == "3"
    end

    test "skips boosts, replies and anything not public" do
      stub_tag_timeline([
        status(%{"id" => "1", "reblog" => %{"id" => "9"}}),
        status(%{"id" => "2", "in_reply_to_id" => "9"}),
        status(%{"id" => "3", "visibility" => "private"}),
        status(%{"id" => "4"})
      ])

      assert {:ok, [post]} = ExternalTagClient.fetch(@source, "Elixir")
      assert post.remote_id == "4"
    end

    test "skips a status with no link, no text or a future date" do
      stub_tag_timeline([
        status(%{"id" => "1", "url" => nil}),
        status(%{"id" => "2", "content" => "  "}),
        status(%{
          "id" => "3",
          "created_at" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
        }),
        status(%{"id" => "4"})
      ])

      assert {:ok, [post]} = ExternalTagClient.fetch(@source, "Elixir")
      assert post.remote_id == "4"
    end

    test "an answer that is not a list of statuses is transient, not a crash" do
      stub_tag_timeline(%{"error" => "nope"})

      assert ExternalTagClient.fetch(@source, "Elixir") == {:error, :transient}
    end

    test "a 404 is gone and a 503 is transient" do
      stub_tag_timeline_status(404)
      assert ExternalTagClient.fetch(@source, "Elixir") == {:error, :gone}

      stub_tag_timeline_status(503)
      assert ExternalTagClient.fetch(@source, "Elixir") == {:error, :transient}
    end

    test "a server that demands an account is gone, not a strike forever" do
      stub_tag_timeline_status(401)
      assert ExternalTagClient.fetch(@source, "Elixir") == {:error, :gone}
    end

    test "a tag whose name leaves nothing a hashtag can be is refused" do
      stub_tag_timeline([status()])

      assert ExternalTagClient.fetch(@source, "???") == {:error, :gone}
      refute_received {:req, _host, _path, _query, _headers}
    end
  end
end
