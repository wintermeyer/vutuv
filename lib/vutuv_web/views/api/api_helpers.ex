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

  def put_relationship(%{relationships: relationships} = struct, key, view, json, params) do
    relationship = view.render(json, params)
    %{struct | relationships: update_relationships(relationships, key, relationship)}
  end

  def put_relationship(struct, key, view, json, params) do
    put_relationship(Map.put(struct, :relationships, %{}), key, view, json, params)
  end

  # This function group ensures if a relationship does not exist, it is not added.
  defp update_relationships(relationships, _, %{data: []}), do: relationships

  defp update_relationships(relationships, _, %{data: nil}), do: relationships

  defp update_relationships(relationships, key, relationship) do
    Map.put(relationships, key, relationship)
  end
end
