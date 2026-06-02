defmodule VutuvWeb.Api.FolloweeJSON do
  @moduledoc false
  import VutuvWeb.Api.ApiHelpers

  @attributes ~w(first_name last_name middlename nickname honorific_prefix honorific_suffix gender birthdate)a

  def render("index.json", %{followees: followees}) do
    %{data: Enum.map(followees, &followee/1)}
  end

  def render("index_lite.json", %{followees: followees}) do
    %{data: Enum.map(followees, &followee_lite/1)}
  end

  def followee(followee) do
    followee_lite(followee)
    |> put_attributes(followee, @attributes)
  end

  def followee_lite(followee) do
    %{id: followee.id, type: "user"}
  end
end
