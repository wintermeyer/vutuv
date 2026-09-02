defmodule VutuvWeb.RegistrationEmailBindingTest do
  @moduledoc """
  What `POST /new_registration` may bind to a brand-new account.

  Exactly one address, the one the login PIN is mailed to. The form only ever
  submits `emails[0]`, but the endpoint is unauthenticated and takes whatever is
  posted, and a bare `cast_assoc(:emails)` used to persist every further entry
  as a login identity for the new account. That is an account-takeover primitive
  rather than an untidy row: `Accounts.user_by_email/1` resolves any stored
  address to its user, so the address's real owner could no longer register, and
  their next login would mail them a valid PIN into somebody else's account.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts.Email
  alias Vutuv.Repo

  test "a second address in the sign-up POST creates no account", %{conn: conn} do
    attrs = registration_attrs("binding")
    mine = attrs["emails"]["0"]["value"]
    theirs = "victim#{System.unique_integer([:positive])}@example.com"

    attrs = put_in(attrs, ["emails", "1"], %{"value" => theirs})

    post(conn, ~p"/new_registration", user: attrs)

    refute Repo.get_by(Email, value: theirs)
    refute Repo.get_by(Email, value: mine)
  end

  # The address the attacker does not own must stay registerable by its owner,
  # which is the harm that outlives the failed sign-up.
  test "the third-party address is still free afterwards", %{conn: conn} do
    attrs = registration_attrs("binding")
    theirs = "victim#{System.unique_integer([:positive])}@example.com"

    post(conn, ~p"/new_registration", user: put_in(attrs, ["emails", "1"], %{"value" => theirs}))

    own = registration_attrs("victim") |> put_in(["emails", "0", "value"], theirs)

    assert {:ok, _user} = Vutuv.Accounts.register_user(conn, own)
    assert Repo.get_by(Email, value: theirs)
  end

  # vutuv is a German site, so the refusal has to read as German. The msgid is
  # new, and a new one-line msgid is exactly what `gettext.extract --merge`
  # likes to fuzzy-fill with somebody else's sentence.
  test "the refusal is shown, in German", %{conn: conn} do
    attrs = registration_attrs("binding")
    theirs = "victim#{System.unique_integer([:positive])}@example.com"

    body =
      conn
      |> put_req_header("accept-language", "de-DE,de")
      |> post(~p"/new_registration", user: put_in(attrs, ["emails", "1"], %{"value" => theirs}))
      |> html_response(422)

    assert body =~ "Bei der Anmeldung kann nur eine E-Mail-Adresse angegeben werden."
  end

  test "the ordinary one-address sign-up still works", %{conn: conn} do
    attrs = registration_attrs("binding")

    post(conn, ~p"/new_registration", user: attrs)

    assert Repo.get_by(Email, value: attrs["emails"]["0"]["value"])
  end
end
