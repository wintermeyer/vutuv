defmodule VutuvWeb.Api.FollowerJSON do
  @moduledoc false
  import VutuvWeb.Api.ApiHelpers

  @attributes ~w(first_name last_name middlename nickname honorific_prefix honorific_suffix gender birthdate)a

  def render("index.json", %{followers: followers}) do
    %{data: Enum.map(followers, &follower/1)}
  end

  def render("index_lite.json", %{followers: followers}) do
    %{data: Enum.map(followers, &follower_lite/1)}
  end

  def follower(follower) do
    follower_lite(follower)
    |> put_attributes(follower, @attributes)
  end

  def follower_lite(follower) do
    %{id: follower.id, type: "user"}
  end
end
