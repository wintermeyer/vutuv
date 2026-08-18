defmodule VutuvWeb.OauthConsentIdempotencyTest do
  @moduledoc """
  One consent, one authorization code (issue #1561).

  A phone client resubmitted a single loaded consent page about a hundred times,
  up to eight times a second, and every submission minted its own code — each a
  bearer credential for ten minutes. The route's budget bounds the rate and
  `OAuth.prune_unused_codes/2` bounds the pile, but neither makes the second
  submission of the *same* consent harmless.

  So the form carries a nonce and the code is **derived** from the consent it
  belongs to (`Vutuv.ApiAuth.OAuth`, peppered HMAC): the second submission finds
  the row the first one wrote and hands back the code that already went out.
  Only the hash of a code is stored, which is why it has to be re-derived rather
  than read back.

  These tests submit **through the rendered form** — the nonce is a hidden field,
  so a hand-built POST would test a page that does not exist. `mix test` runs
  with the rate limiter off, so the route's separate consent budget (covered in
  `oauth_consent_limit_test.exs`) does not cut these runs short.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.MastodonHelpers

  alias Vutuv.ApiAuth.AuthCode
  alias Vutuv.Repo

  @redirect "org.example.client://oauth"

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    {:ok, conn: conn, user: allow_mastodon_clients(user), app: register_mastodon_app()}
  end

  defp consent_page(conn, app) do
    get(
      conn,
      ~p"/oauth/authorize?#{[response_type: "code", client_id: app.client_id, redirect_uri: @redirect, scope: "read"]}"
    )
  end

  # Everything the browser would send back: the hidden fields the page rendered
  # (the nonce among them) plus the button that was pressed.
  defp form_params(page) do
    ~r/<input[^>]*type="hidden"[^>]*>/
    |> Regex.scan(page.resp_body)
    |> Enum.map(fn [input] -> {field(input, "name"), field(input, "value")} end)
    |> Map.new()
    |> Map.put("decision", "allow")
  end

  defp field(input, attribute) do
    case Regex.run(~r/#{attribute}="([^"]*)"/, input) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp submit(conn, params), do: post(conn, ~p"/oauth/authorize", params)

  defp code_of(response) do
    [_, code] = Regex.run(~r/[?&]code=([^&]+)/, redirected_to(response, 302))
    URI.decode(code)
  end

  test "the consent form carries a nonce of its own", %{conn: conn, app: app} do
    params = conn |> consent_page(app) |> form_params()

    assert byte_size(params["consent_nonce"]) > 16

    refute params["consent_nonce"] ==
             (conn |> consent_page(app) |> form_params())["consent_nonce"]
  end

  # The measured failure, in one assertion. Calibrate by dropping the
  # `consent_nonce` field from the template: this goes red with 100 codes.
  test "one page resubmitted a hundred times yields one code", %{conn: conn, app: app} do
    params = conn |> consent_page(app) |> form_params()

    codes = for _ <- 1..100, into: MapSet.new(), do: conn |> submit(params) |> code_of()

    assert MapSet.size(codes) == 1
    assert Repo.aggregate(AuthCode, :count) == 1
  end

  test "and the code it repeats is a working one", %{conn: conn, app: app} do
    params = conn |> consent_page(app) |> form_params()

    first = conn |> submit(params) |> code_of()
    repeat = conn |> submit(params) |> code_of()

    assert repeat == first
    assert %AuthCode{used_at: nil} = Repo.get_by!(AuthCode, code_hash: hash(first))
  end

  # A member connecting the app a second time is consenting a second time, and
  # must not be handed a code that was already spent (or is about to be).
  test "a freshly opened consent page mints a code of its own", %{conn: conn, app: app} do
    first = conn |> consent_page(app) |> form_params() |> then(&submit(conn, &1)) |> code_of()
    second = conn |> consent_page(app) |> form_params() |> then(&submit(conn, &1)) |> code_of()

    refute second == first
    assert Repo.aggregate(AuthCode, :count) == 2
  end

  # Once the code has been redeemed, repeating the page cannot answer with it:
  # a spent code is exactly what makes a replay detectable, so handing it out
  # again would report the member's own client as a thief.
  test "a resubmission after the code was redeemed mints a new one", %{conn: conn, app: app} do
    params = conn |> consent_page(app) |> form_params()
    code = conn |> submit(params) |> code_of()

    Repo.get_by!(AuthCode, code_hash: hash(code))
    |> Ecto.Changeset.change(used_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    later = conn |> submit(params) |> code_of()

    refute later == code
    assert %AuthCode{used_at: %DateTime{}} = Repo.get_by!(AuthCode, code_hash: hash(code))
  end

  # The nonce rides a form, so it is the client's string by the time it comes
  # back. Nothing about a fixed one is dangerous — the only code it can pin is
  # its own — but it must not raise, and it must not reach across members.
  test "two members sending the same nonce get their own codes", %{conn: conn, app: app} do
    params = %{
      "response_type" => "code",
      "client_id" => app.client_id,
      "redirect_uri" => @redirect,
      "scope" => "read",
      "identity" => "person",
      "decision" => "allow",
      "consent_nonce" => "the-same-string"
    }

    {other_conn, other} =
      create_and_login_user(build_conn() |> Plug.Test.init_test_session(%{}))

    allow_mastodon_clients(other)

    mine = conn |> submit(params) |> code_of()
    theirs = other_conn |> submit(params) |> code_of()

    refute theirs == mine
  end

  # N-1: the release before this one rendered a form without the field, and
  # those pages are still open in somebody's browser when the new one takes over.
  test "a page rendered before this shipped still connects", %{conn: conn, app: app} do
    params =
      conn |> consent_page(app) |> form_params() |> Map.delete("consent_nonce")

    assert conn |> submit(params) |> redirected_to(302) =~ "#{@redirect}?code="
  end

  defp hash(code), do: Vutuv.ApiAuth.hash_token(code)
end
