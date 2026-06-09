defmodule VutuvWeb.Api.FollowerJSON do
  @moduledoc false
  import VutuvWeb.Api.ApiHelpers

  @attributes ~w(first_name last_name middle_name nickname honorific_prefix honorific_suffix gender birthdate)a

  def render("index.json", %{followers: followers}) do
    %{data: Enum.map(followers, &follower/1)}
  end

  def follower(follower) do
    %{id: follower.id, type: "user"}
    |> put_attributes(follower, @attributes)
  end
end
