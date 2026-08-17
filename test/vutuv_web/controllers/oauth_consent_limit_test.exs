defmodule VutuvWeb.OauthConsentLimitTest do
  @moduledoc """
  A budget on the consent form's submissions (issue #1561).

  One login through a phone client submitted `POST /oauth/authorize` about a
  hundred times from a single loaded page, up to eight per second, every one a
  302 with a valid CSRF token. `OAuth.approve/3` mints an authorization code per
  submission, so one consent left ~100 spare codes, each redeemable for ten
  minutes. The login itself succeeded, which is why nothing looked wrong from
  outside.

  Nothing of ours resubmits that form — the template is a plain `<.form>` with no
  hook, and the three places in `assets/js` that submit a form belong to the
  Markdown editor, WebAuthn and the Fediverse dialog. So this does not chase the
  client's bug; it bounds what one member and one app can mint, which is a guard
  that holds for the next client too.

  **The budget must not touch a working login**, so it is far above anything a
  person does: nobody presses Allow ten times in a minute, and the first
  submissions still answer exactly as before.

  `async: false` because it flips the rate limiter on, which is global state the
  SQL sandbox does not roll back.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.ApiAuth.AuthCode
  alias Vutuv.Repo

  setup do
    original = Application.fetch_env(:vutuv, :rate_limit)
    Application.put_env(:vutuv, :rate_limit, enabled: true)
    Vutuv.RateLimiter.reset()

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, :rate_limit, was)
        :error -> Application.delete_env(:vutuv, :rate_limit)
      end

      Vutuv.RateLimiter.reset()
    end)

    :ok
  end

  defp consent_params(app) do
    %{
      "response_type" => "code",
      "client_id" => app.client_id,
      "redirect_uri" => "org.example.client://oauth",
      "scope" => "read",
      "identity" => "person",
      "decision" => "allow"
    }
  end

  defp approve(conn, app) do
    conn |> post(~p"/oauth/authorize", consent_params(app))
  end

  # Three times the budget, so a test that asserts a cut-off cannot pass by
  # accident if `@consent_limit` is raised a little.
  defp exhaust_budget(conn, app) do
    for _ <- 1..30, do: approve(conn, app)
    :ok
  end

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    {:ok, conn: conn, user: allow_mastodon_clients(user), app: register_mastodon_app()}
  end

  test "a member consenting once is answered exactly as before", %{conn: conn, app: app} do
    response = approve(conn, app)

    assert redirected_to(response, 302) =~ "org.example.client://oauth?code="
    assert Repo.aggregate(AuthCode, :count) == 1
  end

  # The rate is bounded. Calibrate by removing the `within_consent_budget?/2`
  # guard from `OauthController.decide/4` — this goes red with 30 requests
  # answered.
  test "a runaway client is cut off long before it has submitted a hundred times", %{
    conn: conn,
    app: app
  } do
    answered =
      for _ <- 1..30, do: approve(conn, app).status

    assert Enum.count(answered, &(&1 == 302)) <= 10
    assert 302 in answered, "the first consent must still work"
  end

  # And the pile is bounded, which the rate alone cannot do: a client pacing
  # itself under the budget would still hold codes for their whole ten-minute
  # life. `OAuth.prune_unused_codes/2` is what caps that, so it is asserted on
  # the count of rows rather than on the count of answers.
  test "however it paces itself, only a handful of codes stay redeemable", %{
    conn: conn,
    app: app
  } do
    exhaust_budget(conn, app)

    live = Repo.aggregate(from(c in AuthCode, where: is_nil(c.used_at)), :count)
    assert live <= 3, "#{live} authorization codes are redeemable at once"
    assert live >= 1, "the newest code must survive its own pruning"
  end

  test "past the budget it says so rather than pretending to redirect", %{conn: conn, app: app} do
    exhaust_budget(conn, app)

    assert approve(conn, app).status == 429
  end

  # vutuv is a German site, and a page nobody reads in German is a page nobody
  # checked: the refusal has to say what happened in the reader's language, not
  # fall through to the generic "request is invalid".
  test "and it says it in German to a German reader", %{conn: conn, app: app} do
    exhaust_budget(conn, app)

    body =
      conn
      |> recycle()
      |> put_req_header("accept-language", "de-DE,de")
      |> post(~p"/oauth/authorize", consent_params(app))
      |> html_response(429)

    assert body =~ "zu oft hintereinander um eine Verbindung gebeten"
  end

  # A budget shared across apps would let one looping client lock a member out
  # of connecting a different one.
  test "the budget is per app, so another client still connects", %{conn: conn, app: app} do
    exhaust_budget(conn, app)

    other = register_mastodon_app()

    assert conn
           |> post(~p"/oauth/authorize", consent_params(other))
           |> redirected_to(302) =~ "org.example.client://oauth?code="
  end

  # Denying is not minting: it costs no code, so it must not spend the budget
  # that a later genuine consent needs.
  test "denying does not spend the budget", %{conn: conn, app: app} do
    for _ <- 1..30 do
      post(conn, ~p"/oauth/authorize", %{consent_params(app) | "decision" => "deny"})
    end

    assert Repo.aggregate(AuthCode, :count) == 0
    assert approve(conn, app) |> redirected_to(302) =~ "code="
  end
end
