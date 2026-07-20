defmodule VutuvWeb.PhoneNumberHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  @doc """
  The stored type values are the English option values from the form ("Home",
  "Cell", "Work", "Work Cell" since issue #948); render them through gettext so
  the page speaks the visitor's language. "Fax" and any other unknown legacy
  value still render (Fax is no longer offered, only grandfathered).
  """
  # "Home" reuses the "Private" msgid ("Privat"), so the private landline no
  # longer collides with the navigation "Home" ("Startseite") and needs no
  # gettext context. "Cell" is the private mobile, "Work Cell" the work mobile.
  def phone_type_label("Home"), do: gettext("Private")
  def phone_type_label("Cell"), do: gettext("Private mobile")
  def phone_type_label("Work"), do: gettext("Work")
  def phone_type_label("Work Cell"), do: gettext("Work mobile")
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
