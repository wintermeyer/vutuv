defmodule VutuvWeb.UserProfileCodeStatsTest do
  @moduledoc """
  The "Code" card on the profile (Vutuv.CodeStats, issue #922). Not async:
  the feature flag and the Req seam live in the application env, and the
  app-wide fetcher writes through the shared SQL Sandbox connection.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Profiles.SocialMediaAccount

  @card "#profile-code-stats"

  @snapshot %{
    "followers" => 412,
    "public_repos" => 87,
    "member_since" => "2009-03-01",
    "total_stars" => 2312,
    "languages" => ["Elixir", "Ruby"],
    "last_active_at" => "2026-07-01T10:00:00Z",
    "recent_repos" => 12,
    "top_repos" => [
      %{
        "name" => "generator",
        "url" => "https://github.com/dev/generator",
        "description" => "Static site generator",
        "language" => "Elixir",
        "stars" => 1200
      }
    ]
  }

  defp enable_code_stats do
    Application.put_env(:vutuv, :fetch_code_stats, true)
    on_exit(fn -> Application.put_env(:vutuv, :fetch_code_stats, false) end)
  end

  defp unique_handle, do: "dev#{System.unique_integer([:positive])}"

  defp insert_snapshot_account(user, attrs \\ []) do
    insert(
      :social_media_account,
      Keyword.merge(
        [
          provider: "GitHub",
          value: unique_handle(),
          user: user,
          code_stats: @snapshot,
          code_stats_fetched_at: DateTime.utc_now(:second)
        ],
        attrs
      )
    )
  end

  describe "rendering from the stored snapshot" do
    test "a snapshot-carrying account renders the card with its facts", %{conn: conn} do
      enable_code_stats()
      user = insert_activated_user()
      insert_snapshot_account(user)

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      assert has_element?(view, @card)
      assert has_element?(view, "#{@card} [data-code-stats='GitHub']")
      # 2312 stars compact to "2K"; the repo row keeps its exact-ish count.
      assert has_element?(view, "#{@card} [data-code-stars]", "2K")
      assert has_element?(view, "#{@card} a[href='https://github.com/dev/generator']")
      assert render(view) =~ "Elixir · Ruby"
    end

    test "no card without any snapshot", %{conn: conn} do
      enable_code_stats()
      user = insert_activated_user()
      insert(:social_media_account, provider: "GitHub", value: unique_handle(), user: user)

      {:ok, view, _html} = live(conn, ~p"/#{user}")
      refute has_element?(view, @card)
    end

    test "the flag off hides the card even with a stored snapshot", %{conn: conn} do
      user = insert_activated_user()
      insert_snapshot_account(user)

      {:ok, view, _html} = live(conn, ~p"/#{user}")
      refute has_element?(view, @card)
    end

    test "the member's privacy opt-out hides the card", %{conn: conn} do
      enable_code_stats()
      user = insert_activated_user(show_code_stats?: false)
      insert_snapshot_account(user)

      {:ok, view, _html} = live(conn, ~p"/#{user}")
      refute has_element?(view, @card)
    end
  end

  describe "the agent-format siblings" do
    test "the snapshot's facts appear in HTML, Markdown, text, JSON and XML", %{conn: conn} do
      enable_code_stats()
      user = insert_activated_user(username: "codedrift")
      insert_snapshot_account(user, value: "codedev")

      html = conn |> get(~p"/#{user}") |> html_response(200)
      md = get(build_conn(), "/codedrift.md").resp_body
      txt = get(build_conn(), "/codedrift.txt").resp_body
      json = Jason.decode!(get(build_conn(), "/codedrift.json").resp_body)
      xml = get(build_conn(), "/codedrift.xml").resp_body

      # The card renders in the crawler-visible (disconnected) HTML pass —
      # a DB read, so the static render carries it, unlike the social feed.
      assert html =~ "profile-code-stats"
      assert html =~ "generator"

      for body <- [md, txt] do
        assert body =~ "https://github.com/codedev"
        assert body =~ "2312 stars"
        assert body =~ "87 repositories"
        assert body =~ "generator"
      end

      assert [entry] = json["code_stats"]
      assert entry["provider"] == "GitHub"
      assert entry["total_stars"] == 2312
      assert [%{"name" => "generator", "stars" => 1200}] = entry["top_repos"]

      assert xml =~ "<total_stars>2312</total_stars>"
    end

    test "the member's opt-out empties the docs like the page" do
      enable_code_stats()
      user = insert_activated_user(username: "codeoptout", show_code_stats?: false)
      insert_snapshot_account(user)

      json = Jason.decode!(get(build_conn(), "/codeoptout.json").resp_body)
      assert json["code_stats"] == []
    end
  end

  describe "the background refresh" do
    defp stub_github(handle) do
      Application.put_env(:vutuv, :github_req_options,
        plug: fn conn ->
          body =
            case conn.request_path do
              "/users/" <> ^handle ->
                %{"followers" => 7, "public_repos" => 1, "created_at" => "2010-01-01T00:00:00Z"}

              _repos ->
                [
                  %{
                    "name" => "fresh",
                    "html_url" => "https://github.com/#{handle}/fresh",
                    "description" => nil,
                    "language" => "Elixir",
                    "stargazers_count" => 5,
                    "fork" => false,
                    "pushed_at" => "2026-07-01T10:00:00Z"
                  }
                ]
            end

          Plug.Conn.send_resp(conn, 200, Jason.encode!(body))
        end
      )

      on_exit(fn -> Application.delete_env(:vutuv, :github_req_options) end)
    end

    test "a stale profile view fetches in the background and fills the card live", %{conn: conn} do
      enable_code_stats()
      user = insert_activated_user()
      handle = unique_handle()
      stub_github(handle)
      insert(:social_media_account, provider: "GitHub", value: handle, user: user)

      Vutuv.Activity.subscribe(user.id)
      {:ok, view, _html} = live(conn, ~p"/#{user}")

      # Mount found no snapshot and asked the fetcher; once the broadcast
      # reached us, the view's copy is already in its mailbox, so the next
      # (synchronous) render reflects the fresh snapshot — no reload. (No
      # "card absent first" refute here: the stubbed fetch races the mount.)
      assert_receive {:code_stats_updated, _account_id}

      assert has_element?(view, @card)
      assert has_element?(view, "#{@card} a[href='https://github.com/#{handle}/fresh']")
    end

    test "creating a forge account on the settings page fetches the first snapshot", %{
      conn: conn
    } do
      enable_code_stats()
      handle = unique_handle()
      stub_github(handle)

      {conn, user} = create_and_login_user(conn)
      Vutuv.Activity.subscribe(user.id)

      post(conn, ~p"/settings/social_media_accounts", %{
        "social_media_account" => %{"provider" => "GitHub", "value" => handle}
      })

      assert_receive {:code_stats_updated, _account_id}

      account = Vutuv.Repo.get_by!(SocialMediaAccount, provider: "GitHub", value: handle)
      assert account.code_stats["total_stars"] == 5
      assert %DateTime{} = account.code_stats_fetched_at
    end
  end
end
