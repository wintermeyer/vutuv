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
  alias Vutuv.Accounts.User
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

  # The same question from the other side, and it was open: `cast_assoc(:emails)`
  # carried no `required`, so a POST that spells the address anywhere but
  # `emails[0][value]` minted an account with **no address at all** — one nobody
  # can ever sign into, since the login PIN has nowhere to go. The controller
  # then re-derived the address from the same params, got nil, and 500ed inside
  # `String.downcase/2`. An unauthenticated endpoint, so the shape is somebody
  # else's to send, not only a typo in ours.
  describe "a sign-up with no address" do
    # Asserted on the USER row, not on the Email one: the bug created a user and
    # no address, so `refute Repo.get_by(Email, …)` — the shape the four tests
    # above use — passes against the un-fixed code and proves nothing here.
    test "is refused rather than minting an account nobody can sign into",
         %{conn: conn} do
      attrs = registration_attrs("noaddr")

      conn = post(conn, ~p"/new_registration", user: Map.delete(attrs, "emails"))

      assert html_response(conn, 422)
      refute Repo.get_by(User, first_name: attrs["first_name"])
    end

    # The shape that actually reached production: the address is present, but
    # under a key `cast_assoc` ignores. Registration used to succeed on it.
    test "an address under the wrong key is not an address", %{conn: conn} do
      attrs = registration_attrs("wrongkey")
      value = attrs["emails"]["0"]["value"]

      attrs = attrs |> Map.delete("emails") |> Map.put("email", value)

      conn = post(conn, ~p"/new_registration", user: attrs)

      assert html_response(conn, 422)
      refute Repo.get_by(Email, value: value)
      refute Repo.get_by(User, first_name: attrs["first_name"])
    end

    # The same nil, on the other branch. `several_emails?/1` counts entries, not
    # keys, so ONE address under `emails[1]` passes it and Ecto casts it whatever
    # the key is — but the controller's params extraction only ever matched
    # `emails[0]`. With an address that already belongs to somebody, the insert
    # trips the unique index, the "already taken" path runs, and it used to be
    # handed nil. One unauthenticated POST, and knowing any member's address.
    test "an already-taken address under a non-zero key does not crash the notice",
         %{conn: conn} do
      theirs = registration_attrs("owner")
      post(conn, ~p"/new_registration", user: theirs)
      taken = theirs["emails"]["0"]["value"]

      attrs =
        registration_attrs("collide")
        |> Map.put("emails", %{"1" => %{"value" => taken}})

      conn = post(conn, ~p"/new_registration", user: attrs)

      # The enumeration-safe answer: the same PIN screen a fresh sign-up gets.
      assert html_response(conn, 200)
    end

    # Named for what it pins, which is not the translation: the wizard writes
    # that lead sentence only when some error is bound to a field the form
    # actually marks (`RegistrationLive`'s `@marked_fields`). The changeset's
    # error is on the `:emails` ASSOCIATION, so without the rename to the
    # `email` the form renders, it falls through to `:base` and the refusal
    # arrives as a loose sentence beside an email field that looks fine. The
    # German header stays because vutuv is a German site and the sentence has to
    # read as German where it renders.
    test "the address error marks the email field, so the banner speaks",
         %{conn: conn} do
      attrs = registration_attrs("noaddr")

      body =
        conn
        |> put_req_header("accept-language", "de-DE,de")
        |> post(~p"/new_registration", user: Map.delete(attrs, "emails"))
        |> html_response(422)

      assert body =~ "Bitte prüfen Sie die rot markierten Felder."
    end

    # The claim `registration_changeset/2`'s comment makes about the new
    # `required: true`: the ordinary submit with the field left empty is
    # unaffected, because it posts `emails[0][value]` as "" — which casts, and
    # then fails on the Email changeset's own validation rather than on the
    # association being missing. Untested, that sentence is just a hope.
    test "an empty email field still fails on the field, not on the association",
         %{conn: conn} do
      attrs = registration_attrs("blank") |> put_in(["emails", "0", "value"], "")

      conn = post(conn, ~p"/new_registration", user: attrs)

      assert html_response(conn, 422)
      refute Repo.get_by(User, first_name: attrs["first_name"])
    end
  end
end
