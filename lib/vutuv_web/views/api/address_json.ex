defmodule VutuvWeb.Api.AddressJSON do
  @moduledoc false
  import VutuvWeb.Api.ApiHelpers

  @attributes ~w(description line_1 line_2 line_3 line_4 zip_code city state country)a

  def render("index.json", %{addresses: addresses}) do
    %{data: Enum.map(addresses, &address/1)}
  end

  def render("show.json", %{address: address}) do
    %{data: address(address)}
  end

  def address(address) do
    %{id: address.id, type: "address"}
    |> put_attributes(address, @attributes)
  end
end
