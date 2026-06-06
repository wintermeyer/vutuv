defmodule VutuvWeb.EmailController do
  use VutuvWeb, :controller
  alias Vutuv.Accounts
  alias Vutuv.Accounts.Email
  alias Vutuv.Notifications.Emailer
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.RateLimit

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
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

  # Step 1: mail a PIN for the new address and render the PIN-entry form. The new
  # address rides along in the login_pin's `value` column until it is confirmed.
  def create(conn, %{"email" => email_params}) do
    user = conn.assigns[:current_user]
    email = email_params["value"]

    case RateLimit.check(conn, :email_change, email) do
      :ok ->
        user
        |> Accounts.gen_pin_for("email", email)
        |> Emailer.email_creation_email(email, user)
        |> Emailer.deliver()

        render(conn, "confirm.html", user: conn.assigns[:user])

      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> redirect(to: ~p"/#{conn.assigns[:user]}/emails")
    end
  end

  # Step 2: the PIN confirms the new address, which is then inserted.
  def confirm(conn, %{"email_confirmation" => %{"pin" => pin}}) do
    case RateLimit.check(conn, :email_pin) do
      :ok ->
        verify_email_pin(conn, pin)

      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> redirect(to: ~p"/#{conn.assigns[:user]}/emails")
    end
  end

  defp verify_email_pin(conn, pin) do
    case Accounts.check_pin(conn.assigns[:current_user], pin, "email") do
      {:ok, new_email, user} ->
        user
        |> build_assoc(:emails)
        |> Email.changeset(%{value: new_email})
        |> Repo.insert()
        |> case do
          {:ok, _email} ->
            conn
            |> put_flash(:info, gettext("Email created successfully."))
            |> redirect(to: ~p"/")

          {:error, _changeset} ->
            conn
            |> put_flash(:error, gettext("That email could not be added."))
            |> redirect(to: ~p"/#{conn.assigns[:user]}/emails")
        end

      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> render("confirm.html", user: conn.assigns[:user])

      {:expired, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ~p"/#{conn.assigns[:user]}/emails")

      :lockout ->
        conn
        |> put_flash(:error, gettext("Too many incorrect attempts."))
        |> redirect(to: ~p"/#{conn.assigns[:user]}/emails")
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
      nil -> ControllerHelpers.render_error(conn, 404)
      email -> render(conn, "show.html", email: email)
    end
  end

  # Editing is limited to the public? flag: changing the address itself would
  # bypass the PIN verification above, so a new address means create + delete.
  def edit(conn, %{"id" => id}) do
    email = ControllerHelpers.get_owned!(conn, :emails, id)
    changeset = Email.update_changeset(email)
    render(conn, "edit.html", email: email, changeset: changeset)
  end

  def update(conn, %{"id" => id, "email" => email_params}) do
    email = ControllerHelpers.get_owned!(conn, :emails, id)
    changeset = Email.update_changeset(email, email_params)

    ControllerHelpers.save(conn, Repo.update(changeset),
      flash: gettext("Email updated successfully."),
      redirect_to: &~p"/#{conn.assigns[:user]}/emails/#{&1}",
      render: "edit.html",
      assigns: [email: email]
    )
  end

  def delete(conn, %{"id" => id}) do
    email = ControllerHelpers.get_owned!(conn, :emails, id)

    if Email.can_delete?(conn.assigns.current_user.id) do
      # Here we use delete! (with a bang) because we expect
      # it to always work (and if it does not, it will raise).
      Repo.delete!(email)

      conn
      |> put_flash(:info, gettext("Email deleted successfully."))
      |> redirect(to: ~p"/#{conn.assigns[:user]}/emails")
    else
      conn
      |> put_flash(:error, gettext("Cannot delete final email."))
      |> redirect(to: ~p"/#{conn.assigns[:user]}/emails")
    end
  end
end
