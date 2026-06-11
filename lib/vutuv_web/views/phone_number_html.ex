defmodule VutuvWeb.PhoneNumberHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  @doc """
  The stored type values are the English option values from the form
  ("Work", "Cell", ...); render them through gettext so the page speaks the
  visitor's language. Unknown legacy values pass through unchanged.
  """
  def phone_type_label("Work"), do: gettext("Work")
  def phone_type_label("Cell"), do: gettext("Cell")
  def phone_type_label("Home"), do: gettext("Home")
  def phone_type_label("Fax"), do: gettext("Fax")
  def phone_type_label(other), do: other

  @doc """
  A dialable form of the displayed number: keep digits and a leading `+`,
  drop spacing and punctuation (`tel:` targets must not contain spaces).
  """
  def tel_href(value) do
    String.replace(value, ~r/(?!^\+)[^\d]/, "")
  end

  embed_templates("../templates/phone_number/*")
end
