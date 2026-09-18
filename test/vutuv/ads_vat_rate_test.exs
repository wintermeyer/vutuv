defmodule Vutuv.AdsVatRateTest do
  @moduledoc """
  The ad VAT rate seen from another installation's side.

  `async: false` and a file of its own because it flips the global
  `:ads_vat_percent`, which `Vutuv.Ads.vat_percent/0` and
  `VutuvWeb.AgentDocs.AdsDoc.vat_display/1` read — every other test that renders
  an ad page or an ad mail would see the changed rate for as long as this file
  holds it down.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Ads
  alias VutuvWeb.AgentDocs.AdsDoc

  defp put_vat_percent(percent) do
    original = Application.fetch_env(:vutuv, :ads_vat_percent)
    Application.put_env(:vutuv, :ads_vat_percent, percent)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, :ads_vat_percent, was)
        :error -> Application.delete_env(:vutuv, :ads_vat_percent)
      end
    end)
  end

  test "an installation that charges no VAT quotes no VAT line" do
    put_vat_percent(0)

    assert Ads.gross_cents(35_000) == 35_000
    refute AdsDoc.vat_display()
  end

  test "another country's rate is what the offer quotes" do
    # Italy, for an installation invoicing there: 350,00 € net, 22 % -> 427,00 €.
    put_vat_percent(22)

    assert Ads.gross_cents(35_000) == 42_700
    assert AdsDoc.vat_display() =~ "22"
    assert AdsDoc.vat_display() =~ "427"
  end
end
