defmodule VutuvWeb.Api.GroupJSON do
  @moduledoc false
  import VutuvWeb.Api.ApiHelpers

  @attributes ~w(name)a

  def render("index.json", %{groups: groups}) do
    %{data: Enum.map(groups, &group/1)}
  end

  def render("show.json", %{group: group}) do
    %{data: group(group)}
  end

  def group(group) do
    %{id: group.id, type: "group"}
    |> put_attributes(group, @attributes)
  end
end
