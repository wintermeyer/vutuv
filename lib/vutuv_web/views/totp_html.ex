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

  # One row of the "can't scan it?" list beside the QR code: a heading naming
  # what the member gets to do, one line saying whose case it is, and the
  # control itself in the slot. The three rows are alternatives, not steps, so
  # a hairline separates them and none is numbered — their order is only how
  # likely each is to be the reader's case.
  attr(:title, :string, required: true)
  attr(:hint, :string, required: true)
  slot(:inner_block, required: true)

  defp setup_option(assigns) do
    ~H"""
    <div class="py-4 first:pt-3 last:pb-0">
      <h3 class="text-sm font-semibold text-slate-900 dark:text-white">{@title}</h3>
      <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">{@hint}</p>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
