defmodule VutuvWeb.MastodonApi.CompatibilityController do
  @moduledoc "Small read-only Mastodon resources clients request during startup."

  use VutuvWeb, :controller

  def preferences(conn, _params) do
    json(conn, %{
      "posting:default:visibility" => "public",
      "posting:default:sensitive" => false,
      "posting:default:language" => nil,
      "reading:expand:media" => "default",
      "reading:expand:spoilers" => false
    })
  end

  def markers(conn, _params), do: json(conn, %{})
  def empty(conn, _params), do: json(conn, [])
end
