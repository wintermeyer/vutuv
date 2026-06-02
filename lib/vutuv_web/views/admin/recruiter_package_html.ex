defmodule VutuvWeb.Admin.RecruiterPackageHTML do
  @moduledoc false
  use VutuvWeb, :html

  defp get_currency_symbol("dollar"), do: "$"
  defp get_currency_symbol("euro"), do: "€"
  # Fall back to the raw code so an unmapped/blank currency never produces nil
  # (the template does `get_currency_symbol(...) <> " "`, which would crash).
  defp get_currency_symbol(other), do: to_string(other)

  embed_templates("../../templates/admin/recruiter_package/*")
end
