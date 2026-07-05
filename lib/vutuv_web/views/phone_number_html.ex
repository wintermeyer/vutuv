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
  # "Home" is disambiguated from the navigation "Home" (Startseite): as a phone
  # type it is the private/home number, "Privat" in German.
  def phone_type_label("Home"), do: pgettext("phone number type", "Home")
  def phone_type_label("Fax"), do: gettext("Fax")
  def phone_type_label(other), do: other

  @doc """
  A dialable `tel:` target for the number: the canonical E.164 form when it
  parses, else a digit-stripped fallback. Delegates to `Vutuv.Phone.tel/1` so
  the link form lives in one place (see the profile card in `user/show`).
  """
  defdelegate tel_href(value), to: Vutuv.Phone, as: :tel

  @doc """
  The number in readable international form for display on the (locale-agnostic)
  section and show pages, spacing a legacy run-together value. Delegates to
  `Vutuv.Phone.display/1`; the locale-aware profile card uses `national/2`.
  """
  defdelegate display_number(value), to: Vutuv.Phone, as: :display

  embed_templates("../templates/phone_number/*")
end
