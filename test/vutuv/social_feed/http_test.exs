defmodule Vutuv.SocialFeed.HttpTest do
  @moduledoc """
  The shared outbound GET must hand its callers the RAW body. Every client
  (Mastodon, Bluesky, the code-forge stats) decodes the JSON itself behind an
  `is_binary` guard, and the real APIs mark their answers `application/json` —
  so if Req's own decode step is left on, the body arrives as a map, every
  guard falls through, and each fetch classifies as a transient failure that
  walks the account's backoff ladder to permanent deactivation. Exactly that
  shipped in v7.95.4 (the `into:` collector replaced `decode_body: false`
  instead of joining it) and silently killed all social feeds and code stats
  in production from 2026-07-12 on, while every stub-served test stayed green.
  """
  use ExUnit.Case, async: true

  alias Vutuv.SocialFeed.Http

  # A key of its own so this async test never touches a real provider's seam.
  @options_key :social_feed_http_contract_req_options

  test "get/2 returns a JSON-content-typed body as the raw binary, undecoded" do
    Application.put_env(:vutuv, @options_key,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"handle":"alice"}))
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, @options_key) end)

    assert {:ok, %Req.Response{status: 200, body: body}} =
             Http.get("https://api.example.test/thing", @options_key)

    assert body == ~s({"handle":"alice"})
    assert {:ok, %{"handle" => "alice"}} = Http.decode(body)
  end
end
