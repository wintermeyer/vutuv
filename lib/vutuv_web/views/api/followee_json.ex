defmodule VutuvWeb.Api.FolloweeJSON do
  @moduledoc false
  import VutuvWeb.Api.ApiHelpers

  @attributes ~w(first_name last_name middle_name nickname honorific_prefix honorific_suffix gender birthdate)a

  def render("index.json", %{followees: followees}) do
    %{data: Enum.map(followees, &followee/1)}
  end

  def followee(followee) do
    %{id: followee.id, type: "user"}
    |> put_attributes(followee, @attributes)
  end
end
