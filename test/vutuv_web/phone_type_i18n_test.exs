defmodule VutuvWeb.PhoneTypeI18nTest do
  @moduledoc """
  The phone-number type "Home" must read as the German "Privat", not the bare
  English "Home". The msgid "Home" was overloaded: it also names the navigation
  target ("g h" shortcut, breadcrumb), which is "Startseite". One msgid cannot
  carry both meanings, so the phone type is disambiguated with a gettext context.
  """
  use ExUnit.Case, async: true

  alias VutuvWeb.PhoneNumberHTML

  @backend VutuvWeb.Gettext

  setup do
    Gettext.put_locale(@backend, "de")
    :ok
  end

  test "the phone type labels are all German" do
    assert PhoneNumberHTML.phone_type_label("Work") == "Arbeit"
    assert PhoneNumberHTML.phone_type_label("Cell") == "Mobil-Telefon"
    assert PhoneNumberHTML.phone_type_label("Home") == "Privat"
    assert PhoneNumberHTML.phone_type_label("Fax") == "Fax"
  end

  test "the navigation 'Home' stays 'Startseite', distinct from the phone type" do
    assert Gettext.gettext(@backend, "Home") == "Startseite"
  end
end
