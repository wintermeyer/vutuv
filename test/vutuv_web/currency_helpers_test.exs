defmodule VutuvWeb.CurrencyHelpersTest do
  use ExUnit.Case, async: true

  alias VutuvWeb.CurrencyHelpers

  describe "number_to_currency/2" do
    test "formats positive whole numbers with thousands grouping" do
      assert CurrencyHelpers.number_to_currency(999) == "$999.00"
      assert CurrencyHelpers.number_to_currency(1234567) == "$1,234,567.00"
    end

    test "formats zero" do
      assert CurrencyHelpers.number_to_currency(0) == "$0.00"
    end

    test "groups negative numbers without a stray delimiter after the sign" do
      assert CurrencyHelpers.number_to_currency(-999) == "$-999.00"
      assert CurrencyHelpers.number_to_currency(-1234567) == "$-1,234,567.00"
    end

    test "formats a negative number with cents" do
      assert CurrencyHelpers.number_to_currency(-1234.5) == "$-1,234.50"
    end

    test "returns an empty string for nil" do
      assert CurrencyHelpers.number_to_currency(nil) == ""
    end
  end
end
