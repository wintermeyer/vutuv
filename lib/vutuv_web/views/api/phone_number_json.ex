defmodule VutuvWeb.Api.PhoneNumberJSON do
  @moduledoc false
  import VutuvWeb.Api.ApiHelpers

  @attributes ~w(value number_type)a

  def render("index.json", %{phone_numbers: phone_numbers}) do
    %{data: Enum.map(phone_numbers, &phone_number/1)}
  end

  def render("show.json", %{phone_number: phone_number}) do
    %{data: phone_number(phone_number)}
  end

  def phone_number(phone_number) do
    %{id: phone_number.id, type: "phone_number"}
    |> put_attributes(phone_number, @attributes)
  end
end
