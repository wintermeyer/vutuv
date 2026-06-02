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

        conn = login_via_magic_link(conn, user, "admin@example.com")
        {conn, user}
      end

      defp create_and_login_user(conn, attrs \\ @default_login_attrs) do
        {:ok, user} = Vutuv.Accounts.register_user(conn, attrs)
        conn = login_via_magic_link(conn, user, attrs["emails"]["0"]["value"])
        {conn, user}
      end

      defp login_via_magic_link(conn, user, email) do
        Vutuv.Accounts.login_by_email(conn, email)

        link =
          Repo.one(
            from(m in Vutuv.Accounts.MagicLink,
              where: m.user_id == ^user.id and m.magic_link_type == "login",
              select: m.magic_link
            )
          )

        get(conn, ~p"/magic/login/#{link}")
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
