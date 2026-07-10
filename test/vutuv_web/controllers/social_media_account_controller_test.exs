defmodule VutuvWeb.SocialMediaAccountControllerTest do
  @moduledoc """
  The create action's end-to-end behaviour for the code-forge path guard
  (issue #923): GitLab's reserved numeric-ID URL (gitlab.com/-/u/7984176) can't
  be reduced to a bare handle without rebuilding the wrong link, so the form
  must reject it and save nothing — a plain username still saves. The reduction
  rules themselves live in test/vutuv/profiles/social_media_account_test.exs.
  """
  use VutuvWeb.ConnCase, async: true

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
end
