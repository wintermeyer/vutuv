defmodule VutuvWeb.RegistrationFediverseTest do
  @moduledoc """
  The Fediverse question on the sign-up form (`/`, `POST /new_registration`).

  Most people who join want the connection to Mastodon and friends, so the box
  is ticked by default. Sign-up is the one moment every member passes through,
  while the switch on `/settings/fediverse` is one hardly anybody goes looking
  for — a member who would have said yes never gets asked there.

  One box, all three switches of that page (`Vutuv.Fediverse` participation,
  the reactions that come back, the replies people write out there), so the
  wording carries the weight: the last of those stores text written by people
  who never signed up here, and a consent only covers what it says out loud.

  What the box may not do is federate anything on its own. At sign-up the
  address is still unconfirmed, so `Vutuv.Fediverse.federated?/1` says no and no
  keypair exists; confirmation is the moment both turn true, and it has to mint
  the actor, because the delivery worker silently drops every activity of a
  member who has no key.

  `async: false`: two tests flip `:fediverse_enabled`, application env the SQL
  sandbox does not roll back, and every other test here asserts on the box that
  same switch governs.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse

  describe "GET /" do
    test "offers the Fediverse box, ticked by default", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      # The same sentence the switch on /settings/fediverse wears, so the
      # member recognizes what they are looking for when they want it back.
      assert body =~ "Take part in the Fediverse"
      assert body =~ "Mastodon"
      assert checkbox_checked?(body, "user[fediverse_followers?]")
    end

    # One tick switches all three of the settings page's switches on, and one of
    # those stores what people who never signed up here wrote. A consent covers
    # what it says out loud, so the box has to say it: that replies come back,
    # and that a copy is kept for up to six months.
    test "the box says that replies are stored, and for how long", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      assert body =~ "kept for up to six months"
      assert body =~ "come back under your posts"
      # The two facts that make the tick informed consent: what is stored, and
      # that it can be undone. The sentence was shortened once (2026-08-04) and
      # may be shortened again, but never past these.
      assert body =~ "switch it off at any time"
    end

    # The word is the one thing in that sentence a first-time visitor may not
    # know, so it links out - in BOTH languages. The German string carries the
    # {mastodon} placeholder too, and if it ever loses it `split_marker/2` fails
    # soft: no crash, no link, nobody notices. Hence an assertion per locale.
    test "Mastodon links to the project's own site in either language", %{conn: conn} do
      for locale <- ["en", "de-DE,de;q=0.9"] do
        body =
          conn
          |> put_req_header("accept-language", locale)
          |> get(~p"/")
          |> html_response(200)

        assert body =~ ~s(href="https://joinmastodon.org")
        assert body =~ ">Mastodon</a>"
        # The placeholder itself must never reach the page.
        refute body =~ "{mastodon}"
      end
    end

    # vutuv is a German site, and a new English string on the one page every
    # visitor starts on is an English island nothing else would catch: the test
    # suite and a bare curl both ask for English (see the locale rule).
    test "asks in German when the browser asks in German", %{conn: conn} do
      body =
        conn
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> get(~p"/")
        |> html_response(200)

      assert body =~ "Am Fediverse teilnehmen"
      assert body =~ "bis zu sechs Monate gespeichert"
      assert body =~ "Jederzeit abschaltbar."
    end

    # An intranet installation (FEDIVERSE_ENABLED=false) federates nothing, so
    # the question would promise something it cannot deliver.
    test "asks nothing on an installation that does not federate", %{conn: conn} do
      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)

      body = conn |> get(~p"/") |> html_response(200)

      refute body =~ "user[fediverse_followers?]"
      refute body =~ "Take part in the Fediverse"
    end
  end

  describe "POST /new_registration" do
    # One question on the form, all three switches of /settings/fediverse: the
    # box means taking part, and the box's text says what that includes.
    test "the ticked box switches all three settings on", %{conn: conn} do
      attrs = fediverse_attrs("fedi-on", "true")

      post(conn, ~p"/new_registration", user: attrs)

      user = registered(attrs)
      assert user.fediverse_followers?
      assert user.fediverse_reactions?
      assert user.fediverse_replies?
    end

    # Unticking submits the checkbox's hidden "false", which must land as an
    # account outside the Fediverse — the state the schema default describes.
    test "unticking it leaves the account out", %{conn: conn} do
      attrs = fediverse_attrs("fedi-off", "false")

      post(conn, ~p"/new_registration", user: attrs)

      refute registered(attrs).fediverse_followers?
    end

    # Saying no switches participation off and nothing else: the other two mean
    # nothing while nobody federates, and a member who later says yes on
    # /settings/fediverse — where the switch promises no reply storage — has to
    # land on that page's own defaults, not on an echo of a box they unticked
    # here.
    test "unticking leaves the follow-up switches at their schema defaults", %{conn: conn} do
      attrs = fediverse_attrs("fedi-defaults", "false")

      post(conn, ~p"/new_registration", user: attrs)

      user = registered(attrs)
      assert user.fediverse_reactions?
      refute user.fediverse_replies?
    end

    test "nothing federates while the address is unconfirmed", %{conn: conn} do
      attrs = fediverse_attrs("fedi-pending", "true")

      post(conn, ~p"/new_registration", user: attrs)

      user = registered(attrs)
      assert user.fediverse_followers?
      refute user.email_confirmed?
      refute Fediverse.federated?(user)
      refute Fediverse.get_actor(user)
    end

    # Confirming is the moment `federated?/1` turns true, so it is the moment
    # the signing key has to exist: without it the delivery worker throws away
    # every activity this member queues (their first remote Follow, say) as
    # unsignable, and nothing anywhere says so.
    test "the PIN confirmation mints the actor keypair", %{conn: conn} do
      attrs = fediverse_attrs("fedi-confirm", "true")

      conn = post(conn, ~p"/new_registration", user: attrs)
      post(conn, ~p"/login", session: %{"pin" => sent_pin()})

      user = registered(attrs)
      assert user.email_confirmed?
      assert Fediverse.federated?(user)
      assert Fediverse.get_actor(user)
    end

    test "a member who said no gets no keypair on confirmation", %{conn: conn} do
      attrs = fediverse_attrs("fedi-no-key", "false")

      conn = post(conn, ~p"/new_registration", user: attrs)
      post(conn, ~p"/login", session: %{"pin" => sent_pin()})

      user = registered(attrs)
      assert user.email_confirmed?
      refute Fediverse.get_actor(user)
    end
  end

  defp fediverse_attrs(prefix, value) do
    prefix |> registration_attrs() |> Map.put("fediverse_followers?", value)
  end

  defp registered(%{"emails" => %{"0" => %{"value" => email}}}) do
    Repo.one!(
      from(u in User,
        join: e in assoc(u, :emails),
        where: e.value == ^email
      )
    )
  end
end
