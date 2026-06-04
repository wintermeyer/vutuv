defmodule VutuvWeb.Api.ApiHelpers do
  @moduledoc false

  def put_attributes(map, struct, attributes) do
    Map.put(
      map,
      :attributes,
      struct
      |> Map.from_struct()
      |> Map.take(attributes)
      # removes nil fields
      |> Enum.filter(fn {_, v} -> v != nil end)
      |> Enum.into(%{})
    )
  end
end
