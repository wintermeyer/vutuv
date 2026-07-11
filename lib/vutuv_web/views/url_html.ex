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

  # The compact, human-friendly label for a profile link: just the host,
  # without the `http(s)://` scheme and without the path. When the original
  # URL carried a path, query or fragment a trailing ellipsis is appended so a
  # long link reads as `example.com…` and signals there is more behind it. The
  # full URL stays the clickable target via `linkable_url/1`; this is only the
  # visible text.
  def display_url(string) do
    uri = URI.parse(linkable_url(string))

    case uri.host do
      host when is_binary(host) and host != "" ->
        if uri.path in [nil, "", "/"] and uri.query in [nil, ""] and
             uri.fragment in [nil, ""] do
          host
        else
          host <> "…"
        end

      _ ->
        to_string(string)
    end
  end

  embed_templates("../templates/url/*")

  attr(:url, :map, required: true)
  attr(:method, :string, required: true)
  attr(:label, :string, required: true)

  # One proof method's "Verify now" button: a CSRF form POSTing the chosen
  # method to the verify action. Distinct submit id per method so tests and
  # the browser can target it (verify-rel_me / verify-dns / verify-well_known).
  def verify_form(assigns) do
    ~H"""
    <.form for={%{}} action={~p"/settings/links/#{@url}/verify"} method="post">
      <input type="hidden" name="method" value={@method} />
      <button
        type="submit"
        id={"verify-#{@method}"}
        class="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700"
      >
        {@label}
      </button>
    </.form>
    """
  end
end
