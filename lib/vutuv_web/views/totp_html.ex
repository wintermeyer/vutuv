defmodule VutuvWeb.TotpHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/totp/*")

  @doc """
  The otpauth:// provisioning URI as an inline SVG QR code. Rendered
  server-side (no external service, works air-gapped); plain black on the
  template's always-white backing block, the highest-contrast form for
  camera-based scanners. The URI is our own trusted string, so `raw/1` is
  safe here.
  """
  def qr_svg(uri) do
    uri
    |> EQRCode.encode()
    |> EQRCode.svg(viewbox: true, color: "#000000", background_color: "#FFFFFF")
    |> Phoenix.HTML.raw()
  end
end
