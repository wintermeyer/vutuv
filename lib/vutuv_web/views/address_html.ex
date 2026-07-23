defmodule VutuvWeb.AddressHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  alias Vutuv.Countries

  embed_templates("../templates/address/*")

  @doc """
  The country select's options as `{label, value}` pairs: the **localized**
  country name as the label (so a German visitor reads "Deutschland") and the
  canonical **English** name as the stored value, because that is what
  `addresses.country` has always held and what `Vutuv.Address` branches on.

  Derived from `Vutuv.Countries`, the single source of the country vocabulary —
  including its diacritic-folded sort, so "Ägypten" sorts near "A" instead of
  after "Z". The locale comes from the current gettext process locale, which
  `VutuvWeb.Plug.Locale` sets per request.

  `current` keeps whatever a row already stores selectable even when it is not
  in the ISO list (older imports spell a few countries differently, e.g.
  "Burma"), so editing an address can never silently drop or rewrite its
  country.
  """
  def country_options(current \\ nil) do
    options =
      Enum.map(Countries.select_options(), fn {label, code} ->
        {label, Countries.name(code, "en")}
      end)

    if present_and_unlisted?(current, options), do: options ++ [{current, current}], else: options
  end

  defp present_and_unlisted?(current, options) do
    is_binary(current) and String.trim(current) != "" and
      not Enum.any?(options, fn {_label, value} -> value == current end)
  end
end
