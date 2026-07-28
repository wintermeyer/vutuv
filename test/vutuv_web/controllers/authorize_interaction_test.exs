defmodule VutuvWeb.AuthorizeInteractionTest do
  @moduledoc """
  `GET /authorize_interaction?uri=…` — the door Mastodon (Pleroma, Misskey, …)
  sends somebody through who pressed Follow on an account out there and named
  their vutuv account as the place they are signed in.

  `async: false`: two of these flip `:fediverse_enabled`, the installation-wide
  switch, which lives in the application env and is not rolled back by the SQL
  sandbox.
  """
  use VutuvWeb.ConnCase, async: false

  # The exact shape of the URL from the bug report: Mastodon fills `{uri}` with
  # the profile page of the account you were looking at.
  @account "https://infosec.exchange/@isotopp"
  @address "@isotopp@infosec.exchange"
  @follow_page "/settings/fediverse/following"

  describe "GET /authorize_interaction" do
    test "hands the account over to the follow box", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      conn = get(conn, ~p"/authorize_interaction?#{[uri: @account]}")

      assert redirected_to(conn) == ~p"/settings/fediverse/following?#{[address: @address]}"
    end

    test "reads the other spellings of the same address", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      for uri <- [
            "acct:isotopp@infosec.exchange",
            "@isotopp@infosec.exchange",
            "isotopp@infosec.exchange",
            "https://infosec.exchange/users/isotopp"
          ] do
        conn = get(recycle(conn), ~p"/authorize_interaction?#{[uri: uri]}")

        assert redirected_to(conn) == ~p"/settings/fediverse/following?#{[address: @address]}"
      end
    end

    # Mastodon sends a *post* URL to the same endpoint when the visitor pressed
    # reply or boost rather than follow. vutuv has nothing to offer there, but
    # the author of that post is somebody they can follow.
    test "offers the author when the link points at a single post", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      for uri <- [
            "https://infosec.exchange/@isotopp/115123456789",
            "https://infosec.exchange/users/isotopp/statuses/115123456789"
          ] do
        conn = get(recycle(conn), ~p"/authorize_interaction?#{[uri: uri]}")

        assert redirected_to(conn) == ~p"/settings/fediverse/following?#{[address: @address]}"
        assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "@isotopp@infosec.exchange"
      end
    end

    test "sends a signed-out visitor to log in and back again", %{conn: conn} do
      path = ~p"/authorize_interaction?#{[uri: @account]}"

      conn = get(conn, path)

      assert redirected_to(conn) == ~p"/login"
      assert get_session(conn, :login_return_to) == path
    end

    test "says what is wrong with a link it cannot read", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      conn = get(conn, ~p"/authorize_interaction?#{[uri: "not-an-address"]}")

      assert redirected_to(conn) == @follow_page
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Fediverse"
    end

    test "handles an arrival with no uri at all", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      conn = get(conn, ~p"/authorize_interaction")

      assert redirected_to(conn) == @follow_page
    end

    test "404s while federation is off", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)

      conn = get(conn, ~p"/authorize_interaction?#{[uri: @account]}")

      assert conn.status == 404
    end

    # The switch is the installation's, so it is checked before the login
    # bounce: an endpoint this vutuv does not run must not first ask a visitor
    # to sign in.
    test "404s for a signed-out visitor while federation is off", %{conn: conn} do
      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)

      conn = get(conn, ~p"/authorize_interaction?#{[uri: @account]}")

      assert conn.status == 404
    end
  end
end
