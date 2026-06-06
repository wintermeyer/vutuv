defmodule VutuvWeb.AddressController do
  use VutuvWeb, :controller

  alias Vutuv.Profiles.Address
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.Plug.Locale

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload(:addresses)

    render(conn, "index.html", user: user, addresses: user.addresses)
  end

  def new(conn, _params) do
    changeset = Address.changeset(%Address{}, %{})
    render(conn, "new.html", country: get_template(conn), changeset: changeset)
  end

  def create(conn, %{"address" => address_params}) do
    changeset =
      conn.assigns[:user]
      |> build_assoc(:addresses)
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
    render(conn, "show.html", address: address)
  end

  def edit(conn, %{"id" => id}) do
    address = ControllerHelpers.get_owned!(conn, :addresses, id)
    changeset = Address.changeset(address)
    render(conn, "edit.html", address: address, changeset: changeset, country: get_template(conn))
  end

  def update(conn, %{"id" => id, "address" => address_params}) do
    address = ControllerHelpers.get_owned!(conn, :addresses, id)
    changeset = Address.changeset(address, address_params)

    case Repo.update(changeset) do
      {:ok, address} ->
        conn
        |> put_flash(:info, gettext("Address updated successfully."))
        |> redirect(to: ~p"/#{conn.assigns[:user]}/addresses/#{address}")

      {:error, changeset} ->
        render(conn, "edit.html",
          address: address,
          changeset: changeset,
          country: get_template(conn)
        )
    end
  end

  def delete(conn, %{"id" => id}) do
    address = ControllerHelpers.get_owned!(conn, :addresses, id)

    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Repo.delete!(address)

    conn
    |> put_flash(:info, gettext("Address deleted successfully."))
    |> redirect(to: ~p"/#{conn.assigns[:user]}/addresses")
  end

  defp get_template(conn) do
    loc =
      conn
      |> VutuvWeb.UserHelpers.locale(conn.assigns[:user])

    if Locale.locale_supported?(loc), do: loc, else: "generic"
  end
end
