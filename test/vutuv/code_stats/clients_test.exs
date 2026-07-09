defmodule Vutuv.CodeStats.ClientsTest do
  # Not async: the Req seams live in the application env.
  use ExUnit.Case, async: false

  alias Vutuv.CodeStats.Codeberg
  alias Vutuv.CodeStats.GitHub
  alias Vutuv.CodeStats.GitLab
  alias Vutuv.CodeStats.Snapshot

  defp stub(options_key, fun) do
    Application.put_env(:vutuv, options_key, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, options_key) end)
  end

  describe "Snapshot.build/2" do
    test "aggregates own repos only, forks still count for last activity" do
      own = %{
        name: "hello",
        url: "u",
        description: String.duplicate("x", 200),
        language: "Elixir",
        stars: 5,
        fork?: false,
        pushed_at: ~U[2026-01-01 00:00:00Z]
      }

      fork = %{
        name: "forked",
        url: "u2",
        description: nil,
        language: "Rust",
        stars: 900,
        fork?: true,
        pushed_at: ~U[2026-07-01 00:00:00Z]
      }

      snapshot = Snapshot.build(%{followers: 3, member_since: ~D[2010-05-01]}, [own, fork])

      # The fork's 900 stars and language belong to the upstream, not here.
      assert snapshot["total_stars"] == 5
      assert snapshot["languages"] == ["Elixir"]
      # But pushing to a fork is activity.
      assert snapshot["last_active_at"] == "2026-07-01T00:00:00Z"
      assert snapshot["member_since"] == "2010-05-01"

      assert [%{"name" => "hello", "stars" => 5, "description" => description}] =
               snapshot["top_repos"]

      # Long remote descriptions are stored truncated.
      assert String.length(description) == 160
      assert String.ends_with?(description, "…")
    end
  end

  describe "GitHub.fetch_stats/1" do
    test "a malformed handle is a hard error without any request" do
      assert GitHub.fetch_stats("bad handle!") == {:error, :gone}
      assert GitHub.fetch_stats("-leading-hyphen") == {:error, :gone}
    end

    test "an unknown user (404) is gone" do
      stub(:github_req_options, fn conn -> Plug.Conn.send_resp(conn, 404, "{}") end)
      assert GitHub.fetch_stats("nobody") == {:error, :gone}
    end

    test "a rate-limited answer (403) is transient" do
      stub(:github_req_options, fn conn -> Plug.Conn.send_resp(conn, 403, "{}") end)
      assert GitHub.fetch_stats("octo") == {:error, :transient}
    end

    test "sends the Bearer header once GITHUB_API_TOKEN is configured" do
      Application.put_env(:vutuv, :github_api_token, "ghp_test")
      on_exit(fn -> Application.delete_env(:vutuv, :github_api_token) end)
      test_pid = self()

      stub(:github_req_options, fn conn ->
        send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Plug.Conn.send_resp(conn, 500, "")
      end)

      GitHub.fetch_stats("octo")
      assert_receive {:auth, ["Bearer ghp_test"]}
    end
  end

  describe "GitLab.fetch_stats/1" do
    test "an empty username lookup is gone" do
      stub(:gitlab_req_options, fn conn -> Plug.Conn.send_resp(conn, 200, "[]") end)
      assert GitLab.fetch_stats("nobody") == {:error, :gone}
    end

    test "aggregates the project list; followers and languages stay empty" do
      stub(:gitlab_req_options, fn conn ->
        case conn.request_path do
          "/api/v4/users" ->
            Plug.Conn.send_resp(
              conn,
              200,
              Jason.encode!([%{"id" => 7, "created_at" => "2015-03-01T00:00:00Z"}])
            )

          "/api/v4/users/7/projects" ->
            conn
            |> Plug.Conn.put_resp_header("x-total", "120")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!([
                %{
                  "path" => "tool",
                  "web_url" => "https://gitlab.com/dev/tool",
                  "description" => "A tool",
                  "star_count" => 12,
                  "last_activity_at" => "2026-06-30T08:00:00Z"
                }
              ])
            )
        end
      end)

      assert {:ok, snapshot} = GitLab.fetch_stats("dev")
      assert snapshot["total_stars"] == 12
      assert snapshot["public_repos"] == 120
      assert snapshot["member_since"] == "2015-03-01"
      assert is_nil(snapshot["followers"])
      assert snapshot["languages"] == []
      assert [%{"name" => "tool", "stars" => 12}] = snapshot["top_repos"]
    end
  end

  describe "Codeberg.fetch_stats/1" do
    test "an unknown user (404) is gone" do
      stub(:codeberg_req_options, fn conn -> Plug.Conn.send_resp(conn, 404, "{}") end)
      assert Codeberg.fetch_stats("nobody") == {:error, :gone}
    end

    test "aggregates user + repos, repo total from x-total-count" do
      stub(:codeberg_req_options, fn conn ->
        case conn.request_path do
          "/api/v1/users/dev" ->
            Plug.Conn.send_resp(
              conn,
              200,
              Jason.encode!(%{"followers_count" => 9, "created" => "2020-11-11T00:00:00Z"})
            )

          "/api/v1/users/dev/repos" ->
            conn
            |> Plug.Conn.put_resp_header("x-total-count", "61")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!([
                %{
                  "name" => "berg",
                  "html_url" => "https://codeberg.org/dev/berg",
                  "description" => nil,
                  "language" => "Go",
                  "stars_count" => 3,
                  "fork" => false,
                  "updated_at" => "2026-07-02T12:00:00Z"
                }
              ])
            )
        end
      end)

      assert {:ok, snapshot} = Codeberg.fetch_stats("dev")
      assert snapshot["followers"] == 9
      assert snapshot["public_repos"] == 61
      assert snapshot["member_since"] == "2020-11-11"
      assert snapshot["languages"] == ["Go"]
      assert snapshot["last_active_at"] == "2026-07-02T12:00:00Z"
    end
  end
end
