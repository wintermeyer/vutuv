defmodule VutuvWeb.PhoneNumberController do
  use VutuvWeb, :controller
  alias Vutuv.Profiles.PhoneNumber
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
  plug(:scrub_params, "phone_number" when action in [:create, :update])

  # Index and show are also served as Markdown / text / JSON via
  # VutuvWeb.AgentDocs.SectionDocs (see agent_docs_drift_test.exs).
  def index(conn, _params) do
    phone_numbers = Repo.all(assoc(conn.assigns[:user], :phone_numbers))

    case AgentDocs.negotiate(conn) do
      :html ->
        conn
        |> AgentDocs.put_html_alternates()
        |> render("index.html", phone_numbers: phone_numbers)

      format ->
        doc = SectionDocs.build_index(conn.assigns[:user], :phone_numbers, phone_numbers)
        AgentDocs.send_doc(conn, format, doc)
    end
  end

  def new(conn, _params) do
    changeset =
      conn.assigns[:user]
      |> build_assoc(:phone_numbers)
      |> PhoneNumber.changeset()

    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"phone_number" => phone_number_params}) do
    changeset =
      conn.assigns[:user]
      |> build_assoc(:phone_numbers)
      |> PhoneNumber.changeset(phone_number_params)

    ControllerHelpers.save(conn, Repo.insert(changeset),
      flash: gettext("Phone number created successfully."),
      redirect_to: ~p"/#{conn.assigns[:user]}/phone_numbers",
      render: "new.html"
    )
  end

  def show(conn, %{"id" => id}) do
    phone_number = ControllerHelpers.get_owned!(conn, :phone_numbers, id)

    case AgentDocs.negotiate(conn) do
      :html ->
        conn
        |> AgentDocs.put_html_alternates()
        |> render("show.html", phone_number: phone_number)

      format ->
        doc = SectionDocs.build_show(conn.assigns[:user], :phone_numbers, phone_number)
        AgentDocs.send_doc(conn, format, doc)
    end
  end

  def edit(conn, %{"id" => id}) do
    phone_number = ControllerHelpers.get_owned!(conn, :phone_numbers, id)
    changeset = PhoneNumber.changeset(phone_number)
    render(conn, "edit.html", phone_number: phone_number, changeset: changeset)
  end

  def update(conn, %{"id" => id, "phone_number" => phone_number_params}) do
    phone_number = ControllerHelpers.get_owned!(conn, :phone_numbers, id)
    changeset = PhoneNumber.changeset(phone_number, phone_number_params)

    ControllerHelpers.save(conn, Repo.update(changeset),
      flash: gettext("Phone number updated successfully."),
      redirect_to: &~p"/#{conn.assigns[:user]}/phone_numbers/#{&1}",
      render: "edit.html",
      assigns: [phone_number: phone_number]
    )
  end

  def delete(conn, %{"id" => id}) do
    phone_number = ControllerHelpers.get_owned!(conn, :phone_numbers, id)
    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Repo.delete!(phone_number)

    conn
    |> put_flash(:info, gettext("Phone number deleted successfully."))
    |> redirect(to: ~p"/#{conn.assigns[:user]}/phone_numbers")
  end
end
