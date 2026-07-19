defmodule VutuvWeb.ConnCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest

      alias Vutuv.Repo
      import Ecto.Changeset
      import Ecto.Query
      import Vutuv.Factory
      import Vutuv.MailboxHelpers

      use Phoenix.VerifiedRoutes,
        endpoint: VutuvWeb.Endpoint,
        router: VutuvWeb.Router,
        statics: ~w(assets fonts images favicon.ico)

      @endpoint VutuvWeb.Endpoint

      # Registration requires at least three distinct tags (the sign-up tag
      # minimum), so every helper-registered account carries this neutral,
      # test-greppable trio.
      @registration_tags "alpha-tag beta-tag gamma-tag"

      # Per-call unique sign-up attrs. The email, name and the handle generated
      # from the name are the shared-fixture rows async test modules used to
      # collide on: two modules registering the identical "email@example.com" /
      # "first_name" at once contend on the emails/username/handles unique
      # indexes *inside one register_user transaction*, which is the other half
      # of the intermittent 40P01 deadlock (the tag half is fixed in
      # `Vutuv.Tags.Tag`). Minting a fresh integer per call keeps every
      # registration's rows disjoint, so ConnCase tests are safe to run
      # `async: true`. Tags stay shared on purpose — they get-or-create
      # idempotently now (`Tag.put_created_tag/2`), so they no longer deadlock.
      defp registration_attrs(prefix) do
        n = System.unique_integer([:positive])

        %{
          "emails" => %{"0" => %{"value" => "#{prefix}#{n}@example.com"}},
          "first_name" => "#{prefix}#{n}",
          "tag_list" => @registration_tags
        }
      end

      defp create_and_login_admin(conn) do
        attrs = registration_attrs("admin")
        {:ok, user} = Vutuv.Accounts.register_user(conn, attrs)

        user =
          user
          |> Ecto.Changeset.change(%{admin?: true})
          |> Repo.update!()

        conn = login_via_pin(conn, attrs["emails"]["0"]["value"])
        {conn, user}
      end

      defp create_and_login_user(conn, attrs \\ nil) do
        attrs = attrs || registration_attrs("user")
        {:ok, user} = Vutuv.Accounts.register_user(conn, attrs)
        conn = login_via_pin(conn, attrs["emails"]["0"]["value"])
        {conn, user}
      end

      # Drive the real PIN login: request a PIN, read it from the delivered
      # email, then submit it. The signed identity cookie set by
      # `login_by_email/2` rides along when ConnTest recycles the response.
      defp login_via_pin(conn, email) do
        {:ok, conn} = Vutuv.Accounts.login_by_email(conn, email)
        post(conn, ~p"/login", session: %{"pin" => sent_pin()})
      end

      # The Swoosh test adapter delivers synchronously to this process, so the
      # most recent email is already waiting. The PIN is the only 6-digit run
      # in it. Works for every PIN flow (login, email change, deletion).
      defp sent_pin do
        assert_received {:email, email}
        [pin] = Regex.run(~r/\b\d{6}\b/, email.text_body)
        pin
      end

      # Submit a form the way a browser does: carry the CSRF token rendered into
      # `conn`'s previous response and re-enable CSRF enforcement. `ConnTest`
      # sets `plug_skip_csrf_protection` on every test conn, which is exactly
      # what hid the issue #759 login 403 — so any two-step PIN flow whose second
      # step must survive CSRF should submit through this, not a plain `post/3`.
      #
      # Order matters: `recycle/1` (which carries the response cookies forward)
      # also resets the skip flag, so we flip it off *after* recycling and rely
      # on `phoenix_recycled` to stop `post/3` from recycling a second time.
      defp submit_with_csrf(conn, path, params) do
        conn
        |> recycle()
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> post(path, Map.put(params, "_csrf_token", csrf_token(conn)))
      end

      # Pull the hidden `_csrf_token` value out of the form in `conn`'s response.
      defp csrf_token(conn) do
        [_, token] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, conn.resp_body)
        token
      end

      # ── /api/2.0 helpers (shared by every API test file) ──

      defp authed(conn, token) do
        put_req_header(conn, "authorization", "Bearer " <> token)
      end

      defp json_req(conn, method, token, path, body) do
        conn
        |> authed(token)
        |> put_req_header("content-type", "application/json")
        |> dispatch(@endpoint, method, path, Jason.encode!(body))
      end

      defp json_post(conn, token, path, body), do: json_req(conn, :post, token, path, body)
      defp json_patch(conn, token, path, body), do: json_req(conn, :patch, token, path, body)

      # Decode a problem+json error response, asserting its content type.
      defp api_problem(conn) do
        assert [content_type] = get_resp_header(conn, "content-type")
        assert content_type =~ "application/problem+json"
        Jason.decode!(conn.resp_body)
      end
    end
  end

  setup tags do
    :ok = Sandbox.checkout(Vutuv.Repo)

    unless tags[:async] do
      Sandbox.mode(Vutuv.Repo, {:shared, self()})
    end

    {:ok, conn: Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})}
  end
end
