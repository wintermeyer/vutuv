defmodule VutuvWeb.SettingsBetaTest do
  @moduledoc """
  /settings/beta: one switch for every beta feature, and the list of what it
  currently brings. The form posts through its rendered `action=`.

  Sync because `Vutuv.BetaHelpers.with_beta_features/1` swaps the registry
  through a global application env.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.BetaHelpers

  alias Vutuv.Accounts

  setup do
    with_beta_features()
  end

  test "the hub lists the page", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    body = conn |> get(~p"/settings") |> html_response(200)

    assert body =~ ~s(href="/settings/beta")
  end

  test "the page lists the current beta features with the switch off", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    body = conn |> get(~p"/settings/beta") |> html_response(200)

    assert elements(body, ~s(li[data-beta-feature="test_feature"])) != []
    refute switched_on?(body)
  end

  test "says so when nothing is in beta", %{conn: conn} do
    with_beta_features([])
    {conn, _user} = create_and_login_user(conn)

    body = conn |> get(~p"/settings/beta") |> html_response(200)

    assert body =~ "There are no beta features right now."
  end

  test "the switch saves through the form's own action, on and off", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    body = conn |> get(~p"/settings/beta") |> html_response(200)
    [_, action] = Regex.run(~r/<form[^>]*action="([^"]+)"[^>]*id="beta-form"/, body)

    conn = put(conn, action, %{"user" => %{"beta?" => "true"}})
    assert redirected_to(conn) == ~p"/settings/beta"
    assert Accounts.get_user(user.id).beta?

    assert conn |> get(~p"/settings/beta") |> html_response(200) |> switched_on?()

    conn = put(conn, action, %{"user" => %{"beta?" => "false"}})
    assert redirected_to(conn) == ~p"/settings/beta"
    refute Accounts.get_user(user.id).beta?
  end

  test "an admin sees the same page as everybody", %{conn: conn} do
    {conn, _admin} = create_and_login_admin(conn)

    body = conn |> get(~p"/settings/beta") |> html_response(200)

    assert elements(body, ~s(li[data-beta-feature="test_feature"])) != []
    refute switched_on?(body)
  end

  test "the page and the hub row are translated into German", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    hub = conn |> de() |> get(~p"/settings") |> html_response(200)
    assert hub =~ "Beta-Funktionen"
    assert hub =~ "Neue Funktionen ausprobieren, bevor alle sie bekommen"

    body = conn |> de() |> get(~p"/settings/beta") |> html_response(200)
    assert body =~ "Vor allen anderen ausprobieren"
    assert body =~ "Beta-Funktionen nutzen"
    assert body =~ "Gerade in der Beta"
    assert body =~ "In der Beta seit 1. Oktober 2026"
  end

  defp de(conn), do: conn |> recycle() |> put_req_header("accept-language", "de-DE,de")

  defp switched_on?(body),
    do: elements(body, ~s(#beta-form input[type="checkbox"][checked])) != []
end
