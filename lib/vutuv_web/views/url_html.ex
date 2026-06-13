defmodule VutuvWeb.UrlHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  # The single render chokepoint for a stored profile-link URL. Defense in
  # depth behind the changeset's scheme check: never emit a non-http(s) href
  # (a `javascript:`/`data:` scheme executes on click), so even a legacy or
  # bypassed row renders as an inert "#" rather than a live XSS vector.
  def linkable_url(string) do
    case URI.parse(to_string(string)) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> string
      %URI{scheme: nil} -> "http://#{string}"
      _ -> "#"
    end
  end

  embed_templates("../templates/url/*")
end
