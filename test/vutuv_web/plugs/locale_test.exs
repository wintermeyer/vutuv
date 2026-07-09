defmodule VutuvWeb.Plug.LocaleTest do
  @moduledoc """
  `locale_supported?/1` gates which locales the app accepts (the request-locale
  plug, the address-controller template pick and the emailer language). It must
  test **exact** membership against the configured locales (`~w(en de)`), never a
  substring: a 3-letter subtag that is a superstring of a supported 2-letter code
  ("deu" contains "de", "eng" contains "en") used to false-match under the old
  `String.contains?/2` check.
  """
  use ExUnit.Case, async: true

  alias VutuvWeb.Plug.Locale

  describe "locale_supported?/1" do
    test "the exact configured codes are supported" do
      assert Locale.locale_supported?("de")
      assert Locale.locale_supported?("en")
    end

    test "a 3-letter superstring of a supported code is NOT supported" do
      refute Locale.locale_supported?("deu")
      refute Locale.locale_supported?("eng")
    end

    test "nil and unrelated codes are not supported" do
      refute Locale.locale_supported?(nil)
      refute Locale.locale_supported?("fr")
      refute Locale.locale_supported?("generic")
    end
  end
end
