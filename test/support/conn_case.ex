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

      use Phoenix.VerifiedRoutes,
        endpoint: VutuvWeb.Endpoint,
        router: VutuvWeb.Router,
        statics: ~w(assets fonts images favicon.ico)

      @endpoint VutuvWeb.Endpoint

      @admin_attrs %{
        "emails" => %{"0" => %{"value" => "admin@example.com"}},
        "first_name" => "admin"
      }

      @default_login_attrs %{
        "emails" => %{"0" => %{"value" => "email@example.com"}},
        "first_name" => "first_name"
      }

      defp create_and_login_admin(conn) do
        {:ok, user} = Vutuv.Accounts.register_user(conn, @admin_attrs)

        user =
          user
          |> Ecto.Changeset.change(%{administrator: true})
          |> Repo.update!()

        conn = login_via_pin(conn, "admin@example.com")
        {conn, user}
      end

      defp create_and_login_user(conn, attrs \\ @default_login_attrs) do
        {:ok, user} = Vutuv.Accounts.register_user(conn, attrs)
        conn = login_via_pin(conn, attrs["emails"]["0"]["value"])
        {conn, user}
      end

      # Drive the real PIN login: request a PIN, read it from the delivered
      # email, then submit it. The signed identity cookie set by
      # `login_by_email/2` rides along when ConnTest recycles the response.
      defp login_via_pin(conn, email) do
        {:ok, conn} = Vutuv.Accounts.login_by_email(conn, email)
        post(conn, ~p"/sessions", session: %{"pin" => sent_login_pin()})
      end

      # The Swoosh test adapter delivers synchronously to this process, so the
      # login email is already waiting. The PIN is the only 6-digit run in it.
      defp sent_login_pin do
        assert_received {:email, email}
        [pin] = Regex.run(~r/\b\d{6}\b/, email.text_body)
        pin
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
