defmodule VutuvWeb.Api.UrlJSON do
  @moduledoc false
  import VutuvWeb.Api.ApiHelpers

  @attributes ~w(value description)a

  def render("index.json", %{urls: urls}) do
    %{data: Enum.map(urls, &url/1)}
  end

  def render("index_lite.json", %{urls: urls}) do
    %{data: Enum.map(urls, &url_lite/1)}
  end

  def render("show.json", %{url: url}) do
    %{data: url(url)}
  end

  def render("show_lite.json", %{url: url}) do
    %{data: url_lite(url)}
  end

  def url(url) do
    url_lite(url)
    |> put_attributes(url, @attributes)
  end

  def url_lite(url) do
    %{id: url.id, type: "url"}
  end
end
