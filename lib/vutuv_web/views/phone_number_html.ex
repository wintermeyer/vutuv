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
  A dialable `tel:` target for the number: the canonical E.164 form when it
  parses, else a digit-stripped fallback. Delegates to `Vutuv.Phone.tel/1` so
  the link form lives in one place (see the profile card in `user/show`).
  """
  defdelegate tel_href(value), to: Vutuv.Phone, as: :tel

  embed_templates("../templates/phone_number/*")
end
