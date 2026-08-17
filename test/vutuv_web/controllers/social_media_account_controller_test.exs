defmodule VutuvWeb.SocialMediaAccountControllerTest do
  @moduledoc """
  The create action's end-to-end behaviour for the two code-forge guards.

  Issue #923: GitLab's reserved numeric-ID URL (gitlab.com/-/u/7984176) can't be
  reduced to a bare handle without rebuilding the wrong link, so the form must
  reject it and save nothing — a plain username still saves.

  Issue #1504: a self-hosted Gitea/Forgejo address is only accepted once that
  instance confirms the username, which is what keeps a member-named forge from
  being a free-text field. The reduction rules themselves live in
  test/vutuv/profiles/social_media_account_test.exs.

  Not async: the self-hosted tests flip `:fetch_code_stats` (read by
  Vutuv.CodeStats and the profile renderers) and the Req seam, both global.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Repo

  defp count_for(user),
    do: Repo.aggregate(from(s in SocialMediaAccount, where: s.user_id == ^user.id), :count)

  describe "POST /settings/social_media_accounts" do
    test "rejects GitLab's /-/u/ ID URL and saves nothing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/settings/social_media_accounts", %{
          "social_media_account" => %{
            "provider" => "GitLab",
            "value" => "https://gitlab.com/-/u/7984176"
          }
        })

      assert html_response(conn, 422) =~ "Enter your GitLab username"
      assert count_for(user) == 0
    end

    test "rejects the bare -/u/<id> path and saves nothing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/settings/social_media_accounts", %{
          "social_media_account" => %{"provider" => "GitLab", "value" => "-/u/7984176"}
        })

      assert html_response(conn, 422) =~ "Enter your GitLab username"
      assert count_for(user) == 0
    end

    test "still saves a plain GitLab username", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/settings/social_media_accounts", %{
          "social_media_account" => %{
            "provider" => "GitLab",
            "value" => "https://gitlab.com/wintermeyer"
          }
        })

      assert redirected_to(conn) == ~p"/settings/social_media_accounts"
      assert [%SocialMediaAccount{value: "wintermeyer"}] = Repo.all(SocialMediaAccount)
      assert count_for(user) == 1
    end
  end

  describe "POST /settings/social_media_accounts, a self-hosted forge (#1504)" do
    setup do
      Application.put_env(:vutuv, :fetch_code_stats, true)
      on_exit(fn -> Application.put_env(:vutuv, :fetch_code_stats, false) end)
      on_exit(fn -> Application.delete_env(:vutuv, :forgejo_req_options) end)
      :ok
    end

    defp submit(conn, value) do
      post(conn, ~p"/settings/social_media_accounts", %{
        "social_media_account" => %{"provider" => "Forgejo", "value" => value}
      })
    end

    defp stub_instance(fun), do: Application.put_env(:vutuv, :forgejo_req_options, plug: fun)

    # The same request admits the entry and then fills the "Code" card, so this
    # walks the whole loop: probe, save, background snapshot.
    test "saves the address once the instance confirms the username", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      Vutuv.Activity.subscribe(user.id)

      stub_instance(fn instance ->
        body =
          case instance.request_path do
            "/api/v1/users/hans" ->
              %{"login" => "hans", "followers_count" => 3, "created" => "2021-01-01T00:00:00Z"}

            "/api/v1/users/hans/repos" ->
              [
                %{
                  "name" => "tool",
                  "html_url" => "https://git.example.com/hans/tool",
                  "language" => "Elixir",
                  "stars_count" => 5,
                  "fork" => false,
                  "updated_at" => "2026-07-04T09:00:00Z"
                }
              ]
          end

        instance
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      conn = submit(conn, "https://git.example.com/hans")

      assert redirected_to(conn) == ~p"/settings/social_media_accounts"

      assert [%SocialMediaAccount{value: "hans@git.example.com"} = account] =
               Repo.all(SocialMediaAccount)

      assert count_for(user) == 1

      # The first snapshot is fetched in the background right after the save.
      assert_receive {:code_stats_updated, _id}, 2_000
      assert Repo.reload(account).code_stats["total_stars"] == 5
    end

    test "refuses an address the instance does not know, and saves nothing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      stub_instance(fn instance -> Plug.Conn.send_resp(instance, 404, "{}") end)

      conn = submit(conn, "hans@git.example.com")

      assert html_response(conn, 422) =~ "could not find this account"
      assert count_for(user) == 0
    end

    test "says so plainly when the instance could not be asked", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      stub_instance(fn instance -> Plug.Conn.send_resp(instance, 503, "") end)

      conn = submit(conn, "hans@git.example.com")

      assert html_response(conn, 422) =~ "did not answer"
      assert count_for(user) == 0
    end

    test "a bare username is refused on its shape, without asking anybody", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      stub_instance(fn _instance -> flunk("must not send a request") end)

      conn = submit(conn, "hans")

      assert html_response(conn, 422) =~ "name@git.example.com"
      assert count_for(user) == 0
    end
  end
end
