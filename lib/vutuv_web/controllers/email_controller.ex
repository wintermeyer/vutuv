defmodule VutuvWeb.EmailController do
  use VutuvWeb, :controller
  alias Vutuv.Accounts.Email
  alias Vutuv.Notifications.Emailer

  plug(VutuvWeb.Plug.AuthUser when action not in [:magic_create, :index, :show])
  plug(:scrub_params, "email" when action in [:create, :update])

  def index(conn, _params) do
    emails =
      VutuvWeb.UserHelpers.emails_for_display(conn.assigns[:user], conn.assigns[:current_user])

    emails_counter = length(emails)
    render(conn, "index.html", emails: emails, emails_counter: emails_counter)
  end

  def new(conn, _params) do
    changeset =
      conn.assigns[:user]
      |> build_assoc(:emails)
      |> Email.changeset()

    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"email" => email_params}) do
    email = email_params["value"]

    Vutuv.Accounts.gen_magic_link(conn.assigns[:user], "email", email)
    |> Emailer.email_creation_email(email, conn.assigns[:user])
    |> Vutuv.Mailer.deliver()

    redirect(conn, to: ~p"/")
  end

  def magic_create(conn, %{"magiclink" => link}) do
    Vutuv.Accounts.check_magic_link(link, "email")
    |> case do
      {:ok, email, user} ->
        user
        |> build_assoc(:emails)
        |> Email.changeset(%{value: email})
        |> Repo.insert()
        |> case do
          {:ok, _email} ->
            conn
            |> put_flash(:info, gettext("Email created successfully."))
            |> redirect(to: ~p"/")

          {:error, _changeset} ->
            redirect(conn, to: ~p"/")
        end

      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> redirect(to: ~p"/")
    end
  end

  def show(conn, %{"id" => id}) do
    if VutuvWeb.UserHelpers.user_has_permissions?(
         conn.assigns[:user],
         conn.assigns[:current_user]
       ) do
      Repo.get(assoc(conn.assigns[:user], :emails), id)
    else
      Repo.one(from(e in assoc(conn.assigns[:user], :emails), where: e.public? and e.id == ^id))
    end
    |> case do
      nil ->
        conn
        |> put_status(404)
        |> put_view(html: VutuvWeb.ErrorHTML)
        |> render("404.html")

      email ->
        render(conn, "show.html", email: email)
    end
  end

  def edit(conn, %{"id" => id}) do
    email = Repo.get!(assoc(conn.assigns[:user], :emails), id)
    changeset = Email.changeset(email)
    render(conn, "edit.html", email: email, changeset: changeset)
  end

  def update(conn, %{"id" => id, "email" => email_params}) do
    email = Repo.get!(assoc(conn.assigns[:user], :emails), id)
    changeset = Email.changeset(email, email_params)

    case Repo.update(changeset) do
      {:ok, email} ->
        conn
        |> put_flash(:info, gettext("Email updated successfully."))
        |> redirect(to: ~p"/users/#{conn.assigns[:user]}/emails/#{email}")

      {:error, changeset} ->
        render(conn, "edit.html", email: email, changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    email = Repo.get!(assoc(conn.assigns[:user], :emails), id)
    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    case Email.can_delete?(conn.assigns.current_user.id) do
      true ->
        Repo.delete!(email)

        conn
        |> put_flash(:info, gettext("Email deleted successfully."))
        |> redirect(to: ~p"/users/#{conn.assigns[:user]}/emails")

      false ->
        conn
        |> put_flash(:error, gettext("Cannot delete final email."))
        |> redirect(to: ~p"/users/#{conn.assigns[:user]}/emails")
    end
  end
end
