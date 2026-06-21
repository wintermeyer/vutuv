defmodule VutuvWeb.AddressController do
  use VutuvWeb, :controller

  alias Vutuv.Profiles.Address
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.Plug.Locale

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])

  # Index and show are also served as Markdown / text / JSON via
  # VutuvWeb.AgentDocs.SectionDocs (see agent_docs_drift_test.exs).
  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload(addresses: Address.ordered())

    AgentDocs.respond(conn,
      html: fn conn ->
        conn
        |> VutuvWeb.ViewAs.assign_preview()
        |> render("index.html", user: user, addresses: user.addresses)
      end,
      doc: fn -> SectionDocs.build_index(user, :addresses, user.addresses) end
    )
  end

  def new(conn, _params) do
    changeset = Address.changeset(%Address{}, %{})
    render(conn, "new.html", country: get_template(conn), changeset: changeset)
  end

  def create(conn, %{"address" => address_params}) do
    user = conn.assigns[:user]

    changeset =
      user
      # New entries append to the owner's chosen order (position set on the
      # struct, never cast); reordering lives in VutuvWeb.SectionReorderLive.
      |> build_assoc(:addresses, position: Vutuv.Ordering.next_position(Address, user.id))
      |> Address.changeset(address_params)

    ControllerHelpers.save(conn, Repo.insert(changeset),
      flash: gettext("Address created successfully."),
      redirect_to: ~p"/#{conn.assigns[:user]}/addresses",
      render: "new.html",
      assigns: [country: get_template(conn)]
    )
  end

  def create(conn, %{"country_select" => country_param}) do
    changeset = Address.changeset(%Address{}, country_param)
    render(conn, "new.html", changeset: changeset, country: get_template(conn))
  end

  def show(conn, %{"id" => id}) do
    address = ControllerHelpers.get_owned!(conn, :addresses, id)

    AgentDocs.respond(conn,
      html: &render(&1, "show.html", address: address),
      doc: fn -> SectionDocs.build_show(conn.assigns[:user], :addresses, address) end
    )
  end

  def edit(conn, %{"id" => id}) do
    address = ControllerHelpers.get_owned!(conn, :addresses, id)
    changeset = Address.changeset(address)
    render(conn, "edit.html", address: address, changeset: changeset, country: get_template(conn))
  end

  def update(conn, %{"id" => id, "address" => address_params}) do
    address = ControllerHelpers.get_owned!(conn, :addresses, id)
    changeset = Address.changeset(address, address_params)

    ControllerHelpers.save(conn, Repo.update(changeset),
      flash: gettext("Address updated successfully."),
      redirect_to: &~p"/#{conn.assigns[:user]}/addresses/#{&1}",
      render: "edit.html",
      assigns: [address: address, country: get_template(conn)]
    )
  end

  def delete(conn, %{"id" => id}) do
    address = ControllerHelpers.get_owned!(conn, :addresses, id)

    ControllerHelpers.delete(conn, address,
      flash: gettext("Address deleted successfully."),
      redirect_to: ~p"/#{conn.assigns[:user]}/addresses"
    )
  end

  defp get_template(conn) do
    loc =
      conn
      |> VutuvWeb.UserHelpers.locale(conn.assigns[:user])

    if Locale.locale_supported?(loc), do: loc, else: "generic"
  end
end
