defmodule VutuvWeb.Api.GroupJSON do
  @moduledoc false
  import VutuvWeb.Api.ApiHelpers

  @attributes ~w(name)a

  def render("index.json", %{groups: groups}) do
    %{data: Enum.map(groups, &group/1)}
  end

  def render("index_lite.json", %{groups: groups}) do
    %{data: Enum.map(groups, &group_lite/1)}
  end

  def render("show.json", %{group: group}) do
    %{data: group(group)}
  end

  def render("show_lite.json", %{group: group}) do
    %{data: group_lite(group)}
  end

  def group(group) do
    group_lite(group)
    |> put_attributes(group, @attributes)
  end

  def group_lite(group) do
    %{id: group.id, type: "group"}
  end
end
