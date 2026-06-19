defmodule VutuvWeb.Admin.UsernameController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts.ReservedSlugs
  alias Vutuv.Accounts.User

  def index(conn, _params) do
    render(conn, "index.html")
  end

  # "Disabling" a username means taking it away: the member is force-renamed
  # to a generated handle. The old name is not blocked afterwards (usernames
  # are neither reserved nor redirected anymore); a name bad enough to ban
  # globally belongs in the moderation tooling, not here.
  def update(conn, %{"username_disable" => %{"value" => value}}) do
    case Repo.get_by(User, username: value) do
      nil ->
        conn
        |> put_flash(:error, gettext("No member uses this username."))
        |> render("index.html")

      user ->
        replace_username(conn, user)
    end
  end

  defp replace_username(conn, user) do
    new_handle =
      Vutuv.SlugHelpers.gen_handle_unique(user, User, :username, ReservedSlugs.list())

    case Repo.update(Ecto.Changeset.change(user, username: new_handle)) do
      {:ok, user} ->
        conn
        |> put_flash(
          :info,
          gettext("Username replaced with @%{handle}.", handle: user.username)
        )
        |> redirect(to: ~p"/admin")

      {:error, _changeset} ->
        redirect(conn, to: ~p"/admin")
    end
  end
end
