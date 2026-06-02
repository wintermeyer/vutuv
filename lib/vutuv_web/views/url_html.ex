defmodule VutuvWeb.UrlHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  def linkable_url(string) do
    if Enum.count(String.split(string, "://")) > 1 do
      string
    else
      "http://#{string}"
    end
  end

  embed_templates("../templates/url/*")
end
