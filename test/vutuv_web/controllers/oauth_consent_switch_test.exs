defmodule VutuvWeb.OauthConsentSwitchTest do
  @moduledoc """
  A member whose Mastodon-app switch is off meets it on the consent screen,
  sent there by the app: the screen offers the switch itself and comes back to
  the same request with Allow live, and links the settings page beside it.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.MastodonHelpers

  alias Plug.Conn.Query
  alias Vutuv.AccountEvents.AccountEvent

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    refute user.mastodon_clients?

    {:ok, conn: conn, user: user, app: register_mastodon_app()}
  end

  defp query(app) do
    %{
      "response_type" => "code",
      "client_id" => app.client_id,
      "redirect_uri" => hd(app.redirect_uris),
      "scope" => "read"
    }
  end

  defp consent_page(conn, app), do: get(conn, ~p"/oauth/authorize?#{query(app)}")

  # The switch form as the page rendered it, so the test presses what the
  # member presses: its `action=` and the fields it carries, encoded and decoded
  # the way a browser's submit reaches the controller (`user[…]` nests).
  defp switch_form(page) do
    [form] = elements(page.resp_body, "form#oauth-enable-apps")
    [action] = LazyHTML.attribute(form, "action")

    fields =
      form
      |> LazyHTML.query(~s(input[type="hidden"]))
      |> Map.new(&{hd(LazyHTML.attribute(&1, "name")), hd(LazyHTML.attribute(&1, "value"))})
      |> Query.encode()
      |> Query.decode()

    {action, fields}
  end

  test "with the switch off, the screen offers it and links the setting", %{
    conn: conn,
    app: app
  } do
    page = consent_page(conn, app)
    body = html_response(page, 200)

    assert body =~ "Mastodon client access is disabled for every identity available to you."
    assert body =~ ~s(href="/settings/apps")
    assert body =~ ~s(form="oauth-enable-apps")
    refute body =~ "oauth-allow"

    {action, fields} = switch_form(page)
    assert action == "/settings/apps"
    assert fields["_method"] == "put"
    assert fields["user"] == %{"mastodon_clients?" => "true"}
    assert fields["return_to"] == ~p"/oauth/authorize?#{query(app)}"
  end

  test "one press turns the switch on and lands back on the same request", %{
    conn: conn,
    user: user,
    app: app
  } do
    {action, fields} = conn |> consent_page(app) |> switch_form()

    response = post(conn, action, fields)
    assert redirected_to(response) == ~p"/oauth/authorize?#{query(app)}"
    assert Repo.reload!(user).mastodon_clients?

    assert %AccountEvent{details: %{"enabled" => true}} =
             Repo.get_by!(AccountEvent, user_id: user.id, kind: "mastodon_clients_changed")

    body = conn |> consent_page(app) |> html_response(200)
    assert body =~ "oauth-allow"
    refute body =~ "oauth-enable-apps"
    refute body =~ ~s(href="/settings/apps")
    refute body =~ "Mastodon client access is disabled"
  end

  # The short labels are the likeliest to be fuzzy-filled by a catalog merge,
  # so the German is asserted by name.
  test "in German, offer, link and switch read as written", %{conn: conn, app: app} do
    # `recycle/1` first: the login already sent a response on this conn, and a
    # sent conn refuses a new request header. The header survives the
    # recycling the later requests do on their own.
    conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de")
    page = consent_page(conn, app)
    body = html_response(page, 200)

    assert body =~
             "Schalten Sie ihn für Ihr Konto ein, dann können Sie Pocket Client gleich hier verbinden."

    assert body =~ "App-Einstellungen öffnen"
    assert body =~ "Für mein Konto einschalten"

    {action, fields} = switch_form(page)
    response = post(conn, action, fields)
    body = response |> get(redirected_to(response)) |> html_response(200)
    assert body =~ "App-Einstellungen gespeichert."
    assert body =~ "Zugriff erlauben"
  end

  test "logged out, the switch is not for pressing", %{conn: conn, app: app} do
    {action, fields} = conn |> consent_page(app) |> switch_form()

    assert redirected_to(post(build_conn(), action, fields)) == ~p"/"
  end
end
