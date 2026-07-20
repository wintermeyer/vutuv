defmodule VutuvWeb.PhoneTypeI18nTest do
  @moduledoc """
  The phone-number types (issue #948: private/work × landline/mobile) render
  through gettext so the page speaks the visitor's language. The private
  landline reuses the "Private" msgid ("Privat"), so it no longer collides with
  the navigation "Home" ("Startseite") and needs no gettext context. "Fax" is
  no longer offered but legacy rows must still render their German label.
  """
  use ExUnit.Case, async: true

  alias VutuvWeb.PhoneNumberHTML

  @backend VutuvWeb.Gettext

  setup do
    Gettext.put_locale(@backend, "de")
    :ok
  end

  test "the phone type labels are all German" do
    assert PhoneNumberHTML.phone_type_label("Home") == "Privat"
    assert PhoneNumberHTML.phone_type_label("Cell") == "Mobil (privat)"
    assert PhoneNumberHTML.phone_type_label("Work") == "Arbeit"
    assert PhoneNumberHTML.phone_type_label("Work Cell") == "Mobil (Arbeit)"
    # Fax is no longer offered, but legacy rows keep their German label.
    assert PhoneNumberHTML.phone_type_label("Fax") == "Fax"
  end

  test "the navigation 'Home' stays 'Startseite', distinct from the phone type" do
    assert Gettext.gettext(@backend, "Home") == "Startseite"
  end
end
