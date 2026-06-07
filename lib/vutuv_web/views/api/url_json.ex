defmodule VutuvWeb.Api.UrlJSON do
  @moduledoc false
  import VutuvWeb.Api.ApiHelpers

  @attributes ~w(value description)a

  def render("index.json", %{urls: urls}) do
    %{data: Enum.map(urls, &url/1)}
  end

  def render("show.json", %{url: url}) do
    %{data: url(url)}
  end

  def url(url) do
    %{id: url.id, type: "url"}
    |> put_attributes(url, @attributes)
  end
end
