defmodule VutuvWeb.Admin.UsernameController do
  use VutuvWeb, :controller

  alias Vutuv.AccountEvents
  alias Vutuv.Accounts
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
    # Through the handle chokepoint, not a raw `get_by`: handles are stored
    # downcased and the site shows every one of them with a leading `@`, so an
    # admin pasting `@handle` — or typing a capital — got a flat "No member uses
    # this username", which reads as "that account is gone". A wrong answer on a
    # moderation tool. It takes an email address too, which is usually what an
    # admin has in hand from a report.
    case value |> String.trim() |> Accounts.get_user_by_handle_or_email() do
      nil ->
        conn
        |> put_flash(:error, gettext("No member uses this username."))
        |> render("index.html")

      user ->
        replace_username(conn, user)
    end
  end

  defp replace_username(conn, user) do
    old_handle = user.username

    new_handle =
      Vutuv.SlugHelpers.gen_handle_unique(user, User, :username, ReservedSlugs.list())

    case Repo.update(Ecto.Changeset.change(user, username: new_handle)) do
      {:ok, user} ->
        # The member did not do this, so their activity log has to say so
        # (issue #1087): the acting admin is recorded, which is what turns a
        # baffled "my name changed by itself" into an answerable question.
        AccountEvents.record(user, "username_changed",
          conn: conn,
          factor: "admin",
          actor: conn.assigns[:current_user],
          details: %{from: old_handle, to: user.username}
        )

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
