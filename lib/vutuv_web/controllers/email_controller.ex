defmodule VutuvWeb.EmailController do
  use VutuvWeb, :controller
  alias Vutuv.Accounts
  alias Vutuv.Accounts.Email
  alias Vutuv.Notifications.Emailer
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.RateLimit

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
  plug(:scrub_params, "email" when action in [:create, :update])

  # Index and show are also served as Markdown / text / JSON via
  # VutuvWeb.AgentDocs.SectionDocs. The agent formats render strictly the
  # anonymous view: public addresses only, whoever asks.
  def index(conn, _params) do
    AgentDocs.respond(conn,
      html: fn conn ->
        # The public showcase view for everyone, the owner included: public
        # addresses only. Private addresses show solely on /settings/emails.
        emails = VutuvWeb.UserHelpers.emails_for_display(conn.assigns[:user], nil)

        render(conn, "index.html",
          emails: emails,
          emails_counter: length(emails),
          as_owner?: false
        )
      end,
      doc: fn ->
        emails = VutuvWeb.UserHelpers.emails_for_display(conn.assigns[:user], nil)
        SectionDocs.build_index(conn.assigns[:user], :emails, emails)
      end
    )
  end

  # The owner's editor (GET /settings/emails): every address, private ones
  # included, with the add tile, reorder tool and per-row actions.
  def manage(conn, _params) do
    emails = VutuvWeb.UserHelpers.emails_for_permission(conn.assigns[:user], true)

    render(conn, "manage.html",
      emails: emails,
      emails_counter: length(emails),
      as_owner?: true,
      page_title: gettext("Email addresses")
    )
  end

  def new(conn, _params) do
    changeset =
      conn.assigns[:user]
      |> build_assoc(:emails)
      |> Email.changeset()

    render(conn, "new.html", changeset: changeset)
  end

  # Step 1: mail a PIN for the new address and render the PIN-entry form. The new
  # address rides along in the login_pin's `payload` column until it is confirmed.
  #
  # The address format is validated up front (the same Email.changeset that
  # step 2 inserts through) so a malformed address is rejected here instead of
  # after the member has chased down and entered a PIN we mailed to a bogus
  # address — and so we never mail a PIN to something that isn't an address.
  def create(conn, %{"email" => email_params}) do
    user = conn.assigns[:current_user]
    email = email_params["value"]

    changeset =
      user
      |> build_assoc(:emails)
      |> Email.changeset(email_params)

    with {:ok, _} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- RateLimit.check(conn, :email_change, email) do
      user
      |> Accounts.gen_pin_for("email", email)
      |> Emailer.email_creation_email(email, user)
      |> Emailer.deliver()

      conn
      # The login_pin payload is a single string already carrying the new
      # address, so the chosen Work/Personal/Other label waits in the
      # session until step 2's PIN confirms the address.
      |> put_session(:pending_email_type, email_params["email_type"])
      |> render("confirm.html", user: conn.assigns[:user])
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "new.html", changeset: changeset)

      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> redirect(to: ~p"/settings/emails")
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
        |> redirect(to: ~p"/settings/emails")
    end
  end

  defp verify_email_pin(conn, pin) do
    case Accounts.check_pin(conn.assigns[:current_user], pin, "email") do
      {:ok, new_email, user} ->
        email_type = get_session(conn, :pending_email_type) || "Other"

        user
        # Append to the owner's chosen order (position set on the struct, never
        # cast); reordering lives in VutuvWeb.SectionReorderLive.
        |> build_assoc(:emails, position: Vutuv.Ordering.next_position(Email, user.id))
        |> Email.changeset(%{value: new_email, email_type: email_type})
        |> Repo.insert()
        |> case do
          {:ok, _email} ->
            conn
            |> delete_session(:pending_email_type)
            |> put_flash(:info, gettext("Email created successfully."))
            |> redirect(to: ~p"/")

          {:error, _changeset} ->
            conn
            |> put_flash(:error, gettext("That email could not be added."))
            |> redirect(to: ~p"/settings/emails")
        end

      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> render("confirm.html", user: conn.assigns[:user])

      {:expired, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ~p"/settings/emails")

      :lockout ->
        conn
        |> put_flash(:error, gettext("Too many incorrect attempts."))
        |> redirect(to: ~p"/settings/emails")
    end
  end

  def show(conn, %{"id" => id}) do
    case AgentDocs.negotiate(conn) do
      :html -> show_html(conn, id)
      format -> show_doc(conn, format, id)
    end
  end

  defp show_html(conn, id) do
    email =
      if VutuvWeb.UserHelpers.user_has_permissions?(
           conn.assigns[:user],
           conn.assigns[:current_user]
         ) do
        Repo.get(assoc(conn.assigns[:user], :emails), id)
      else
        public_email(conn, id)
      end

    case email do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      email ->
        conn
        |> maybe_put_alternates(email)
        |> render("show.html", email: email)
    end
  end

  # Advertise the agent-format siblings only for a public address — show_doc
  # serves the anonymous view, so a private email's .md/.txt/.json would 404.
  defp maybe_put_alternates(conn, %{public?: true}), do: AgentDocs.put_html_alternates(conn)
  defp maybe_put_alternates(conn, _email), do: conn

  # The anonymous view: a private address has no agent documents, even for a
  # permitted viewer's session — only the public-scoped query runs here, no
  # permission check.
  defp show_doc(conn, format, id) do
    case public_email(conn, id) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      email ->
        doc = SectionDocs.build_show(conn.assigns[:user], :emails, email)
        AgentDocs.send_doc(conn, format, doc)
    end
  end

  defp public_email(conn, id) do
    Repo.one(from(e in assoc(conn.assigns[:user], :emails), where: e.public? and e.id == ^id))
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
      redirect_to: fn _email -> ~p"/settings/emails" end,
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
      |> redirect(to: ~p"/settings/emails")
    else
      conn
      |> put_flash(:error, gettext("Cannot delete final email."))
      |> redirect(to: ~p"/settings/emails")
    end
  end
end
