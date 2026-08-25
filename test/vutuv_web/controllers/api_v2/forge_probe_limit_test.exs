defmodule VutuvWeb.ApiV2.ForgeProbeLimitTest do
  @moduledoc """
  Saving a self-hosted Gitea/Forgejo address makes this server send one request
  to a host the member typed (issue #1504). `VutuvWeb.RateLimit`'s own comment
  says why that is budgeted at 20/hour: *a form anybody can re-submit in a loop
  is a form anybody can point at a stranger.*

  The HTML form asked that budget. `/api/2.0` called `CodeStats.verify_instance/1`
  straight, so the same outbound probe was bounded only by the generic 5,000/hour
  token budget — 250× the deliberate one, on the one request an authenticated
  caller can aim anywhere. `Ssrf.resolves_to_internal?/1` still blocks internal
  addresses, so this was external amplification rather than SSRF.

  `async: false`: the probe stub and `:fetch_code_stats` are global application
  env, and `RateLimiter` state is a shared table.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.ApiAuth

  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()
    # The limiter is OFF in the test env, so a test that does not turn it on
    # cannot see a refusal at all — it would pass with the budget unasked, which
    # is the very thing being pinned here.
    put_config(:rate_limit, enabled: true)
    Application.put_env(:vutuv, :fetch_code_stats, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :fetch_code_stats, false)
      Application.delete_env(:vutuv, :forgejo_req_options)
    end)

    user = insert_activated_user()

    {:ok, token, _} =
      ApiAuth.create_pat(user, %{"name" => "rw", "scopes" => ["profile:write"]})

    # Every probe answers "yes, that user exists", so nothing but the budget can
    # refuse the save.
    Application.put_env(:vutuv, :forgejo_req_options,
      plug: fn instance ->
        instance
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"login": "hans", "id": 1}))
      end
    )

    {:ok, conn: conn, user: user, token: token}
  end

  # `get_env(key)` answers nil for "absent" and for "holds nil" alike, so the
  # obvious `put_env(key, get_env(key))` restore poisons a key that was absent.
  # Capture with `fetch_env/2` and restore the two cases apart.
  defp put_config(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  # The `name@host` form the parser reads (a URL is accepted too and normalizes
  # to it). A distinct host each time, so nothing but the budget can refuse.
  defp save_forge(token, n) do
    json_post(build_conn(), token, "/api/2.0/me/social_media_accounts", %{
      provider: "Forgejo",
      value: "hans@git#{n}.example.com"
    })
  end

  test "the API pays the same 20/hour probe budget the form does", %{token: token} do
    # 20 is `RateLimit`'s @probe_limit. Well past it, and far under the generic
    # 5,000/hour token budget that was the only thing bounding this before.
    refusals =
      for n <- 1..24 do
        save_forge(token, n)
      end
      |> Enum.count(&(&1.status == 422))

    assert refusals > 0,
           "24 outbound probes through the API and not one was refused — the " <>
             "probe budget is not being asked"
  end
end
