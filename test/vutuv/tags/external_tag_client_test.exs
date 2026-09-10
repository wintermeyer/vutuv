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

  # Every Finch a pinned request started, by the name it registers under. Empty
  # is the claim: one instance lives for one request and is stopped in an
  # `after`, so nothing accumulates however many hostnames members name.
  defp pinned_finch_names do
    Enum.filter(Process.registered(), fn name ->
      String.starts_with?(Atom.to_string(name), "Elixir.Vutuv.SocialFeed.Http.Pinned")
    end)
  end

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
      # The identity half: Mint verifies the certificate against this hostname
      # and offers it in SNI, while the socket goes to the vetted IP. Drop that
      # one key and both fall back to the IP literal with every test still
      # green, which is why it is asserted directly.
      pools = Http.pinned_pools(@source, {93, 184, 216, 34})
      assert pools.default[:conn_opts][:hostname] == @source

      # The request half: the Finch to send through, and the `Host` header
      # written out so the virtual host is named whatever the transport decides.
      options = Http.pin(@source, :some_finch)
      assert options[:finch] == :some_finch
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

    test "keeps a post whose author's name is long, clamped rather than refused" do
      # 100 ZWJ family emoji: 100 graphemes, 700 codepoints, 2,500 bytes. A
      # `validate_length(max: 255)` counts the 100 and waves it through, which
      # is how this reached a varchar(255) as a Postgres 22001 on a path with no
      # form in front of it. Refusing the post would be the wrong answer too —
      # it is an ordinary fediverse display name.
      name = String.duplicate("👨‍👩‍👧‍👦", 100)
      stub_tag_timeline([status(%{"account" => %{"acct" => "ada", "display_name" => name}})])

      assert {:ok, [post]} = ExternalTagClient.fetch(@source, "Elixir")
      assert byte_size(post.author_name) <= 255
      assert String.valid?(post.author_name)
      assert String.starts_with?(name, post.author_name)
    end

    test "drops a status whose id is not a token, and keeps one whose language is not" do
      stub_tag_timeline([
        status(%{"id" => String.duplicate("x", 300)}),
        status(%{"id" => "2", "language" => String.duplicate("d", 100)}),
        status(%{"id" => "3"})
      ])

      assert {:ok, [second, third]} = ExternalTagClient.fetch(@source, "Elixir")

      # An over-long id names nothing that can be filed, so that status goes; an
      # over-long language is simply not a language, so the post stays without.
      assert second.remote_id == "2"
      assert second.language == nil
      assert third.remote_id == "3"
    end

    test "drops a status whose author cannot be parsed, rather than letting it past the blocklist" do
      stub_tag_timeline([
        status(%{"id" => "1", "account" => %{"display_name" => "No address"}}),
        status(%{"id" => "2", "account" => nil}),
        status(%{"id" => "3"})
      ])

      assert {:ok, [post]} = ExternalTagClient.fetch(@source, "Elixir")
      assert post.remote_id == "3"
    end

    test "a pinned request leaves no connection pool behind, whatever host it named" do
      stub_tag_timeline([])
      path = "/api/v1/timelines/tag/Elixir?limit=1"

      for n <- 1..5 do
        assert {:ok, %Req.Response{}} =
                 Http.get_pinned("h#{n}.example", path, :external_tag_req_options)
      end

      # Which hostnames appear here is decided by what members type into a
      # followed tag's sources, so the mechanism has to be bounded rather than
      # merely small: handing Req a per-host `connect_options` makes it start a
      # Finch instance per distinct hostname and never reap it.
      assert pinned_finch_names() == []

      # And bounded in atoms, not only in processes. A name minted per request
      # is worse than the leak it replaced — Finch derives four more atoms from
      # each one and atoms are never reclaimed — so the names come from a fixed
      # compile-time list.
      assert length(Http.pinned_slot_names()) == 16
      assert Enum.all?(Http.pinned_slot_names(), &is_atom/1)
    end

    test "never hands Req both a Finch and connect options" do
      # Unobservable end to end: `Req.Steps.put_plug/1` swaps the adapter out
      # before the Finch step validates anything, so a request that raises
      # `cannot set both :finch and :connect_options` against a real server
      # sails through every stubbed test. The base options are where the second
      # one comes from, so dropping it from the caller's own list is not enough.
      options =
        Http.request_options(
          "https://93.184.216.34/api/v1/timelines/tag/Elixir",
          :external_tag_req_options,
          Http.pin(@source, :some_finch)
        )

      assert options[:finch] == :some_finch
      refute Keyword.has_key?(options, :connect_options)
    end

    test "a tag whose name leaves nothing a hashtag can be is refused" do
      stub_tag_timeline([status()])

      assert ExternalTagClient.fetch(@source, "???") == {:error, :gone}
      refute_received {:req, _host, _path, _query, _headers}
    end
  end
end
