defmodule VutuvWeb.UserProfileBlueskyTest do
  @moduledoc """
  The inline Bluesky feed on the profile's "Social media posts" card — the
  Bluesky-specific wiring plus the cross-provider merge; the generic feed
  behaviors (spinner, cached failures, disconnected pass) are covered by
  `VutuvWeb.UserProfileMastodonTest`. Not async: the feature flags and the
  Req seams live in the application env, and the app-wide social feed cache
  writes fetch state through the shared SQL Sandbox connection. Every test
  uses its own handle so the shared cache cannot leak between them.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.SocialFeed.Cache

  @section "#profile-social-posts"

  defp unique_handle, do: "alice#{System.unique_integer([:positive])}.bsky.social"

  defp enable_bluesky do
    Application.put_env(:vutuv, :fetch_bluesky_posts, true)
    on_exit(fn -> Application.put_env(:vutuv, :fetch_bluesky_posts, false) end)
    Cache.reset()
    on_exit(fn -> Cache.reset() end)
  end

  defp stub_bluesky(fun) do
    Application.put_env(:vutuv, :bluesky_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :bluesky_req_options) end)
  end

  @avatar_bytes <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0>>

  # Serves a one-post Bluesky feed (display name "Alice Himmel", a PNG
  # avatar) and reports every request as `{:req, path}`.
  defp serve_one_post(handle, text) do
    test_pid = self()

    stub_bluesky(fn conn ->
      send(test_pid, {:req, conn.request_path})

      case conn.request_path do
        "/xrpc/app.bsky.actor.getProfile" ->
          Plug.Conn.send_resp(
            conn,
            200,
            Jason.encode!(%{
              "did" => "did:plc:abc",
              "handle" => handle,
              "displayName" => "Alice Himmel",
              "avatar" => "https://cdn.example/img/avatar/alice.jpg",
              "labels" => []
            })
          )

        "/xrpc/app.bsky.feed.getAuthorFeed" ->
          Plug.Conn.send_resp(
            conn,
            200,
            Jason.encode!(%{"feed" => [feed_item(handle, text)]})
          )

        "/img/avatar/alice.jpg" ->
          conn
          |> Plug.Conn.put_resp_content_type("image/png")
          |> Plug.Conn.send_resp(200, @avatar_bytes)
      end
    end)
  end

  defp feed_item(handle, text, attrs \\ %{}) do
    %{
      "post" => %{
        "uri" => "at://did:plc:abc/app.bsky.feed.post/3sky",
        "author" => %{"did" => "did:plc:abc", "handle" => handle},
        "record" =>
          Map.merge(
            %{"createdAt" => "2026-07-02T10:00:00.000Z", "text" => text},
            attrs
          ),
        "labels" => []
      }
    }
  end

  defp owner_with_bluesky(handle, user_attrs \\ []) do
    owner = insert_activated_user(user_attrs)
    insert(:social_media_account, provider: "Bluesky", value: handle, user: owner)
    owner
  end

  defp warm_cache(provider, handle) do
    Cache.request(provider, handle, self())
    assert_receive {:social_feed_posts, ^provider, ^handle, result}
    result
  end

  describe "with the feature on" do
    setup do
      enable_bluesky()
      :ok
    end

    test "cached Bluesky posts render with the first connected mount", %{conn: conn} do
      handle = unique_handle()
      owner = owner_with_bluesky(handle)
      serve_one_post(handle, "Hello from the butterfly network")

      assert {:ok, _} = warm_cache("Bluesky", handle)

      {:ok, view, html} = live(conn, ~p"/#{owner}")

      assert html =~ "Hello from the butterfly network"
      assert has_element?(view, @section)

      post_url = "https://bsky.app/profile/#{handle}/post/3sky"
      # The whole row clicks through to the post (the stretched overlay).
      assert has_element?(view, ~s(#{@section} a.inset-0[href="#{post_url}"]))

      # The post row mirrors the post-card header: display name + the
      # server-fetched data-URI avatar (never a hotlink to the CDN).
      assert html =~ "Alice Himmel"
      avatar_src = view |> element(~s(#{@section} img[data-avatar])) |> render()
      assert avatar_src =~ "data:image/png;base64,"
      refute avatar_src =~ "cdn.example"

      # The avatar carries the network badge, so cross-posted entries from
      # different networks stay distinguishable.
      assert has_element?(view, ~s(#{@section} [data-feed-network="Bluesky"]))

      # The plain account row keeps its profile link next to the posts.
      profile_url = "https://bsky.app/profile/#{handle}"
      assert has_element?(view, ~s(#profile-social-media a[href="#{profile_url}"]))
    end

    test "Mastodon and Bluesky posts merge newest-first into one card", %{conn: conn} do
      bluesky_handle = unique_handle()
      mastodon_handle = "anna#{System.unique_integer([:positive])}@example.social"

      Application.put_env(:vutuv, :fetch_mastodon_posts, true)
      on_exit(fn -> Application.put_env(:vutuv, :fetch_mastodon_posts, false) end)

      owner = owner_with_bluesky(bluesky_handle)
      insert(:social_media_account, provider: "Mastodon", value: mastodon_handle, user: owner)

      # Bluesky's post (2026-07-02, from serve_one_post) is newer than the
      # Mastodon one below (2026-07-01). The two clients stub through
      # separate seams, so both can serve at once.
      serve_one_post(bluesky_handle, "Neuer Bluesky-Beitrag")

      Application.put_env(:vutuv, :mastodon_req_options,
        plug: fn conn ->
          case conn.request_path do
            "/api/v1/accounts/lookup" ->
              Plug.Conn.send_resp(
                conn,
                200,
                Jason.encode!(%{"id" => "7", "display_name" => "Anna Anders"})
              )

            "/api/v1/accounts/7/statuses" ->
              Plug.Conn.send_resp(
                conn,
                200,
                Jason.encode!([
                  %{
                    "id" => "71",
                    "created_at" => "2026-07-01T09:00:00.000Z",
                    "content" => "<p>Älterer Mastodon-Beitrag</p>",
                    "url" => "https://example.social/@anna/71",
                    "visibility" => "public",
                    "sensitive" => false,
                    "spoiler_text" => ""
                  }
                ])
              )
          end
        end
      )

      on_exit(fn -> Application.delete_env(:vutuv, :mastodon_req_options) end)

      assert {:ok, _} = warm_cache("Bluesky", bluesky_handle)
      assert {:ok, _} = warm_cache("Mastodon", mastodon_handle)

      {:ok, view, html} = live(conn, ~p"/#{owner}")

      assert has_element?(view, @section)
      assert html =~ "Alice Himmel"
      assert html =~ "Anna Anders"

      {bluesky_at, _} = :binary.match(html, "Neuer Bluesky-Beitrag")
      {mastodon_at, _} = :binary.match(html, "Älterer Mastodon-Beitrag")
      assert bluesky_at < mastodon_at

      # Each entry names its network via the avatar badge — the one visible
      # difference when the same text is cross-posted to both.
      assert has_element?(view, ~s(#{@section} [data-feed-network="Bluesky"]))
      assert has_element?(view, ~s(#{@section} [data-feed-network="Mastodon"]))
    end

    test "identical cross-posts collapse into one row wearing both network badges", %{conn: conn} do
      bluesky_handle = unique_handle()
      mastodon_handle = "anna#{System.unique_integer([:positive])}@example.social"

      Application.put_env(:vutuv, :fetch_mastodon_posts, true)
      on_exit(fn -> Application.put_env(:vutuv, :fetch_mastodon_posts, false) end)

      owner = owner_with_bluesky(bluesky_handle)
      insert(:social_media_account, provider: "Mastodon", value: mastodon_handle, user: owner)

      # The same posting on both networks: Mastodon carries the full text,
      # the Bluesky copy is the truncated crosspost (300-char cap), fired a
      # minute later.
      full_text =
        "Wenn die Leute mal ihre eigenen Jobs so schnell und gründlich machen würden, " <>
          "wie sie es bei Bauwerksanierungen fordern, dann wäre schon viel gewonnen."

      truncated = String.slice(full_text, 0, 80) <> "…"

      serve_one_post(bluesky_handle, truncated)

      Application.put_env(:vutuv, :mastodon_req_options,
        plug: fn conn ->
          case conn.request_path do
            "/api/v1/accounts/lookup" ->
              Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"id" => "7"}))

            "/api/v1/accounts/7/statuses" ->
              Plug.Conn.send_resp(
                conn,
                200,
                Jason.encode!([
                  %{
                    "id" => "71",
                    "created_at" => "2026-07-02T09:59:00.000Z",
                    "content" => "<p>#{full_text}</p>",
                    "url" => "https://example.social/@anna/71",
                    "visibility" => "public",
                    "sensitive" => false,
                    "spoiler_text" => ""
                  }
                ])
              )
          end
        end
      )

      on_exit(fn -> Application.delete_env(:vutuv, :mastodon_req_options) end)

      assert {:ok, _} = warm_cache("Bluesky", bluesky_handle)
      assert {:ok, _} = warm_cache("Mastodon", mastodon_handle)

      {:ok, view, html} = live(conn, ~p"/#{owner}")

      assert has_element?(view, @section)

      # One row, not two: the section's list carries a single entry...
      rows =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#profile-social-posts li")

      assert Enum.count(rows) == 1

      # ...showing the fullest copy (Mastodon's untruncated text), wearing
      # BOTH network badges.
      section_html = view |> element(@section) |> render()
      assert section_html =~ "viel gewonnen"
      refute section_html =~ "…"
      assert has_element?(view, ~s(#{@section} li [data-feed-network="Mastodon"]))
      assert has_element?(view, ~s(#{@section} li [data-feed-network="Bluesky"]))
    end

    test "the owner's opt-out hides the Bluesky feed and stops the fetch", %{conn: conn} do
      handle = unique_handle()
      serve_one_post(handle, "Should stay invisible")
      owner = owner_with_bluesky(handle, show_mastodon_feed?: false)

      assert {:ok, _} = warm_cache("Bluesky", handle)

      {:ok, view, html} = live(conn, ~p"/#{owner}")

      refute html =~ "Should stay invisible"
      refute has_element?(view, @section)
      # The account row itself still shows.
      profile_url = "https://bsky.app/profile/#{handle}"
      assert has_element?(view, ~s(#profile-social-media a[href="#{profile_url}"]))
    end
  end

  describe "with the feature off (the test default)" do
    test "no section renders and no fetch happens, even with an account", %{conn: conn} do
      handle = unique_handle()
      owner = owner_with_bluesky(handle)

      test_pid = self()

      stub_bluesky(fn conn ->
        send(test_pid, {:req, conn.request_path})
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      refute has_element?(view, @section)
      refute_receive {:req, _}
    end
  end
end
