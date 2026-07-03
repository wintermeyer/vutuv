defmodule VutuvWeb.UserProfileMastodonTest do
  @moduledoc """
  The inline Mastodon feed on the profile's Social Media card. Not async: the
  feature flag and the Req seam live in the application env, and the app-wide
  FeedCache writes fetch state through the shared SQL Sandbox connection.
  Every test uses its own handle so the shared cache cannot leak between them.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Mastodon.Feed
  alias Vutuv.Mastodon.FeedCache
  alias Vutuv.Mastodon.Post
  alias Vutuv.Profiles.SocialMediaAccount

  @section "#profile-social-posts"
  @spinner "#profile-social-media [data-mastodon-loading]"

  defp unique_handle, do: "alice#{System.unique_integer([:positive])}@example.social"

  # The account row's rel="me" profile link for a stored user@instance handle.
  defp row_url(handle) do
    [user, instance] = String.split(handle, "@", parts: 2)
    "https://#{instance}/@#{user}"
  end

  defp enable_mastodon do
    Application.put_env(:vutuv, :fetch_mastodon_posts, true)
    on_exit(fn -> Application.put_env(:vutuv, :fetch_mastodon_posts, false) end)
    FeedCache.reset()
    on_exit(fn -> FeedCache.reset() end)
  end

  defp stub_mastodon(fun) do
    Application.put_env(:vutuv, :mastodon_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :mastodon_req_options) end)
  end

  @avatar_bytes <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0>>

  # Serves a one-post feed (display name "Alice Beispiel", a PNG avatar) and
  # reports every request as `{:req, path}`.
  defp serve_one_post(text) do
    test_pid = self()

    stub_mastodon(fn conn ->
      send(test_pid, {:req, conn.request_path})

      case conn.request_path do
        "/api/v1/accounts/lookup" ->
          Plug.Conn.send_resp(
            conn,
            200,
            Jason.encode!(%{
              "id" => "42",
              "display_name" => "Alice Beispiel",
              "avatar_static" => "https://example.social/avatars/alice.png"
            })
          )

        "/api/v1/accounts/42/statuses" ->
          Plug.Conn.send_resp(
            conn,
            200,
            Jason.encode!([
              %{
                "id" => "1",
                "created_at" => "2026-07-01T10:30:00.000Z",
                "content" => "<p>#{text}</p>",
                "url" => "https://example.social/@alice/1",
                "visibility" => "public",
                "sensitive" => false,
                "spoiler_text" => ""
              }
            ])
          )

        "/avatars/alice.png" ->
          conn
          |> Plug.Conn.put_resp_content_type("image/png")
          |> Plug.Conn.send_resp(200, @avatar_bytes)
      end
    end)
  end

  defp failing_stub do
    test_pid = self()

    stub_mastodon(fn conn ->
      send(test_pid, {:req, conn.request_path})
      Plug.Conn.send_resp(conn, 500, "boom")
    end)
  end

  defp one_status(text, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "1",
        "created_at" => "2026-07-01T10:30:00.000Z",
        "content" => "<p>#{text}</p>",
        "url" => "https://example.social/@alice/1",
        "visibility" => "public",
        "sensitive" => false,
        "spoiler_text" => ""
      },
      attrs
    )
  end

  # Like serve_one_post/1, but the lookup blocks inside the fetch task until
  # the test sends `:go` — the window in which the account row must show its
  # loading spinner. Reports requests as `{:req, path, plug_pid}`.
  defp serve_held_post(text) do
    test_pid = self()

    stub_mastodon(fn conn ->
      send(test_pid, {:req, conn.request_path, self()})
      respond_held(conn, text)
    end)
  end

  defp respond_held(%{request_path: "/api/v1/accounts/lookup"} = conn, _text) do
    receive do
      :go -> :ok
    end

    Plug.Conn.send_resp(
      conn,
      200,
      Jason.encode!(%{"id" => "42", "display_name" => "Alice Beispiel"})
    )
  end

  defp respond_held(%{request_path: "/api/v1/accounts/42/statuses"} = conn, text) do
    Plug.Conn.send_resp(conn, 200, Jason.encode!([one_status(text)]))
  end

  # Serves two accounts (anna@example.social and bob@other.social) with one
  # post each — Anna's newer than Bob's.
  defp serve_two_accounts do
    test_pid = self()

    stub_mastodon(fn conn ->
      send(test_pid, {:req, conn.request_path})
      respond_two(conn)
    end)
  end

  defp respond_two(%{request_path: "/api/v1/accounts/lookup", query_string: "acct=anna"} = conn) do
    Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"id" => "1", "display_name" => "Anna Anders"}))
  end

  defp respond_two(%{request_path: "/api/v1/accounts/lookup", query_string: "acct=bob"} = conn) do
    Plug.Conn.send_resp(
      conn,
      200,
      Jason.encode!(%{"id" => "2", "display_name" => "Bob Beispiel"})
    )
  end

  defp respond_two(%{request_path: "/api/v1/accounts/1/statuses"} = conn) do
    Plug.Conn.send_resp(
      conn,
      200,
      Jason.encode!([
        one_status("Annas neuer Beitrag", %{
          "id" => "11",
          "created_at" => "2026-07-02T10:00:00.000Z",
          "url" => "https://example.social/@anna/11"
        })
      ])
    )
  end

  defp respond_two(%{request_path: "/api/v1/accounts/2/statuses"} = conn) do
    Plug.Conn.send_resp(
      conn,
      200,
      Jason.encode!([
        one_status("Bobs älterer Beitrag", %{
          "id" => "21",
          "created_at" => "2026-07-01T09:00:00.000Z",
          "url" => "https://other.social/@bob/21"
        })
      ])
    )
  end

  defp owner_with_mastodon(handle, user_attrs \\ []) do
    owner = insert_activated_user(user_attrs)
    insert(:social_media_account, provider: "Mastodon", value: handle, user: owner)
    owner
  end

  defp warm_cache(handle) do
    FeedCache.request(handle, self())
    assert_receive {:mastodon_posts, ^handle, result}
    result
  end

  describe "with the feature on" do
    setup do
      enable_mastodon()
      :ok
    end

    test "posts already cached render with the first connected mount", %{conn: conn} do
      handle = unique_handle()
      owner = owner_with_mastodon(handle)
      serve_one_post("Hello from the fediverse")

      assert {:ok, _} = warm_cache(handle)

      {:ok, view, html} = live(conn, ~p"/#{owner}")

      assert html =~ "Hello from the fediverse"
      assert has_element?(view, @section)
      assert has_element?(view, ~s(#{@section} a[href="https://example.social/@alice/1"]))
      # The whole row clicks through to the status (the stretched overlay).
      assert has_element?(
               view,
               ~s(#{@section} a.inset-0[href="https://example.social/@alice/1"])
             )

      # The post row mirrors the post-card header: display name + the
      # server-fetched data-URI avatar (never a hotlink to the instance).
      assert html =~ "Alice Beispiel"
      assert has_element?(view, ~s(#{@section} img[data-avatar]))
      avatar_src = view |> element(~s(#{@section} img[data-avatar])) |> render()
      assert avatar_src =~ "data:image/png;base64,"
      refute avatar_src =~ "https://example.social/avatars"
      # The plain account row keeps its rel="me" link next to the posts.
      assert has_element?(view, ~s(#profile-social-media a[href="#{row_url(handle)}"]))
    end

    test "posts arriving after mount render without a reload", %{conn: conn} do
      handle = unique_handle()
      owner = owner_with_mastodon(handle)
      # The mount-time fetch fails; the posts then arrive as the cache message.
      failing_stub()

      {:ok, view, _html} = live(conn, ~p"/#{owner}")
      refute has_element?(view, @section)

      feed = %Feed{
        name: "Alice",
        handle: handle,
        url: row_url(handle),
        avatar: nil,
        posts: [
          %Post{
            id: "9",
            url: "https://example.social/@alice/9",
            text: "Fresh toot",
            created_at: ~U[2026-07-01 10:30:00Z]
          }
        ]
      }

      send(view.pid, {:mastodon_posts, handle, {:ok, feed}})
      assert render(view) =~ "Fresh toot"
      assert has_element?(view, @section)
      # No avatar in the feed -> the initials tile stands in, like a
      # picture-less member.
      assert has_element?(view, ~s(#{@section} span[data-avatar]))

      # A result for some other handle changes nothing.
      send(view.pid, {:mastodon_posts, "other@example.social", {:ok, %{feed | posts: []}}})
      assert has_element?(view, @section)
    end

    test "the loading spinner shows on the account row while the fetch runs", %{conn: conn} do
      handle = unique_handle()
      owner = owner_with_mastodon(handle)
      serve_held_post("Held toot")

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      # The fetch is blocked inside its task: spinner on, no posts card yet.
      assert has_element?(view, @spinner)
      refute has_element?(view, @section)

      assert_receive {:req, "/api/v1/accounts/lookup", task_pid}
      # Join the fetch's waiter list so the test is notified from the same
      # fan-out as the view; the get_state call then syncs the view's mailbox.
      FeedCache.request(handle, self())
      send(task_pid, :go)
      assert_receive {:mastodon_posts, ^handle, {:ok, _}}
      _ = :sys.get_state(view.pid)

      refute has_element?(view, @spinner)
      assert has_element?(view, @section)
      assert render(view) =~ "Held toot"
    end

    test "posts from several accounts merge newest-first into one card", %{conn: conn} do
      owner = insert_activated_user()

      insert(:social_media_account,
        provider: "Mastodon",
        value: "anna@example.social",
        user: owner
      )

      insert(:social_media_account, provider: "Mastodon", value: "bob@other.social", user: owner)
      serve_two_accounts()

      assert {:ok, _} = warm_cache("anna@example.social")
      assert {:ok, _} = warm_cache("bob@other.social")

      {:ok, view, html} = live(conn, ~p"/#{owner}")

      assert has_element?(view, @section)
      assert html =~ "Anna Anders"
      assert html =~ "Bob Beispiel"

      # Anna's post (2026-07-02) is newer than Bob's (2026-07-01), so it
      # renders first even though the accounts are separate feeds.
      {anna_at, _} = :binary.match(html, "Annas neuer Beitrag")
      {bob_at, _} = :binary.match(html, "Bobs älterer Beitrag")
      assert anna_at < bob_at
    end

    test "post bodies run through the member-post pipeline", %{conn: conn} do
      handle = unique_handle()
      owner = owner_with_mastodon(handle)
      tag = insert(:tag, name: "Crochet", slug: "crochet")
      insert(:user_tag, user: owner, tag: tag)

      serve_one_post("Ein **fetter** Gruß #Crochet an @somebody")

      assert {:ok, _} = warm_cache(handle)
      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      # Markdown renders, hashtags link to our tag pages, and a Mastodon
      # @mention never links to a vutuv member.
      assert has_element?(view, ~s(#{@section} .markdown strong))
      assert has_element?(view, ~s(#{@section} a.hashtag[href="/tags/crochet"]))
      refute has_element?(view, ~s(#{@section} a.mention))
      assert render(view) =~ "@somebody"
    end

    test "a member without a Mastodon account triggers no fetch", %{conn: conn} do
      owner = insert_activated_user()
      insert(:social_media_account, provider: "GitHub", value: "octo", user: owner)
      failing_stub()

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      refute has_element?(view, @section)
      refute_receive {:req, _}
    end

    test "the owner's opt-out hides the feed and stops the fetch", %{conn: conn} do
      handle = unique_handle()
      serve_one_post("Should stay invisible")
      owner = owner_with_mastodon(handle, show_mastodon_feed?: false)

      assert {:ok, _} = warm_cache(handle)

      {:ok, view, html} = live(conn, ~p"/#{owner}")

      refute html =~ "Should stay invisible"
      refute has_element?(view, @section)
      # The account row itself still shows.
      assert has_element?(view, ~s(#profile-social-media a[href="#{row_url(handle)}"]))
    end

    test "a deactivated account is never fetched", %{conn: conn} do
      handle = unique_handle()
      owner = owner_with_mastodon(handle)

      Repo.update_all(SocialMediaAccount,
        set: [fetch_disabled_at: DateTime.utc_now(:second)]
      )

      failing_stub()

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      refute has_element?(view, @section)
      refute_receive {:req, _}
    end

    test "a cached failure renders the plain row and does not re-ask", %{conn: conn} do
      handle = unique_handle()
      owner = owner_with_mastodon(handle)
      failing_stub()

      assert {:error, :transient} = warm_cache(handle)
      assert_receive {:req, "/api/v1/accounts/lookup"}

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      refute has_element?(view, @section)
      assert has_element?(view, ~s(#profile-social-media a[href="#{row_url(handle)}"]))
      refute_receive {:req, _}
    end

    test "the disconnected pass never includes Mastodon posts", %{conn: conn} do
      handle = unique_handle()
      owner = owner_with_mastodon(handle)
      serve_one_post("Connected only")

      assert {:ok, _} = warm_cache(handle)

      html = conn |> get(~p"/#{owner}") |> html_response(200)

      refute html =~ "Connected only"
      refute html =~ "profile-social-posts"
      # The plain account link is part of the crawler-visible HTML.
      assert html =~ row_url(handle)
    end
  end

  describe "with the feature off (the test default)" do
    test "no section renders and no fetch happens, even with an account", %{conn: conn} do
      handle = unique_handle()
      owner = owner_with_mastodon(handle)
      failing_stub()

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      refute has_element?(view, @section)
      refute_receive {:req, _}

      # Even a stray cache message cannot switch the feed on.
      feed = %Feed{name: "Alice", handle: handle, url: row_url(handle), posts: []}
      send(view.pid, {:mastodon_posts, handle, {:ok, feed}})
      refute has_element?(view, @section)
    end
  end
end
