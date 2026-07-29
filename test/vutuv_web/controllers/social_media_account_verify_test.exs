defmodule VutuvWeb.SocialMediaAccountVerifyTest do
  @moduledoc """
  The owner-only "prove this Bluesky account is mine" page and the POST behind
  it.

  Not async: the feature flag (`:verify_social_accounts`) and the Req seam
  (`:bluesky_req_options`) both live in the application env, which the SQL
  sandbox does not roll back.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Repo

  @handle "alice.bsky.social"

  defp enable do
    Application.put_env(:vutuv, :verify_social_accounts, true)
    on_exit(fn -> Application.put_env(:vutuv, :verify_social_accounts, false) end)
  end

  defp serve_bio(description) do
    Application.put_env(:vutuv, :bluesky_req_options,
      plug: fn conn ->
        Plug.Conn.send_resp(
          conn,
          200,
          Jason.encode!(%{
            "did" => "did:plc:abc",
            "handle" => @handle,
            "displayName" => "Alice",
            "description" => description,
            "labels" => []
          })
        )
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :bluesky_req_options) end)
  end

  defp bluesky_account(user, handle \\ @handle),
    do: insert(:social_media_account, provider: "Bluesky", value: handle, user: user)

  describe "GET /settings/social_media_accounts/:id/verify" do
    setup do
      enable()
      :ok
    end

    test "shows the address to paste and posts to its own URL", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      account = bluesky_account(user)

      conn = get(conn, ~p"/settings/social_media_accounts/#{account}/verify")
      html = html_response(conn, 200)

      # The exact address the member must put in their bio.
      assert html =~ url(~p"/#{user}")

      # The form must submit to the route that exists — a hand-built path in a
      # test would not have caught the retired-URL class of bug (see CLAUDE.md).
      assert html =~ ~s(action="#{~p"/settings/social_media_accounts/#{account}/verify"}")
    end

    test "a network with no proof says so instead of offering the check", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      account = insert(:social_media_account, provider: "LinkedIn", value: "alice", user: user)

      conn = get(conn, ~p"/settings/social_media_accounts/#{account}/verify")
      html = html_response(conn, 200)

      assert html =~ "cannot be verified yet"
      refute html =~ "Run the check"
    end

    test "another member's account is not reachable", %{conn: conn} do
      stranger = insert_activated_user()
      account = bluesky_account(stranger, "bob.bsky.social")
      {conn, _user} = create_and_login_user(conn)

      assert_error_sent(404, fn ->
        get(conn, ~p"/settings/social_media_accounts/#{account}/verify")
      end)
    end
  end

  describe "POST /settings/social_media_accounts/:id/verify" do
    setup do
      enable()
      :ok
    end

    test "a bio carrying the profile URL earns the mark", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      account = bluesky_account(user)
      serve_bio("Hallo! Mehr über mich: #{url(~p"/#{user}")}")

      conn = post(conn, ~p"/settings/social_media_accounts/#{account}/verify")

      assert redirected_to(conn) == ~p"/settings/social_media_accounts/#{account}/verify"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "verified"

      reloaded = Repo.get!(SocialMediaAccount, account.id)
      assert reloaded.verified_at
      assert reloaded.verification_method == "bluesky_bio"
    end

    test "a bio without the URL leaves the account unverified", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      account = bluesky_account(user)
      serve_bio("Nothing here.")

      conn = post(conn, ~p"/settings/social_media_accounts/#{account}/verify")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "could not find"
      assert Repo.get!(SocialMediaAccount, account.id).verified_at == nil
    end

    test "the mark shows on the public section page for every viewer", %{conn: conn} do
      {owner_conn, user} = create_and_login_user(conn)
      account = bluesky_account(user)
      serve_bio("Mehr: #{url(~p"/#{user}")}")

      post(owner_conn, ~p"/settings/social_media_accounts/#{account}/verify")

      # A signed-out visitor sees the emerald mark, not just the owner.
      html =
        build_conn()
        |> get(~p"/#{user}/social_media_accounts")
        |> html_response(200)

      assert html =~ "Verified profile"
    end
  end

  describe "with the flag off" do
    test "the page says so and the check refuses", %{conn: conn} do
      Application.put_env(:vutuv, :verify_social_accounts, false)
      {conn, user} = create_and_login_user(conn)
      account = bluesky_account(user)

      html =
        conn |> get(~p"/settings/social_media_accounts/#{account}/verify") |> html_response(200)

      assert html =~ "disabled on this installation"

      conn = post(conn, ~p"/settings/social_media_accounts/#{account}/verify")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "disabled"
      assert Repo.get!(SocialMediaAccount, account.id).verified_at == nil
    end
  end
end
