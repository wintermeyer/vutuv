defmodule VutuvWeb.EmailComponents do
  @moduledoc """
  The shared HTML-email framework: one `email_layout/1` chrome plus a small set
  of inline-styled building blocks (`email_p`, `email_pin`, `email_button`,
  `email_panel`/`email_row`, `email_list`, `email_divider`, `email_muted`,
  `email_signature`). Every HTML email body (`lib/vutuv_web/templates/email_body/`)
  composes these, so the look and feel is defined in exactly one place.

  HTML email cannot use the web design system (Tailwind / `components.css`):
  clients want table-based layout and **inline** styles, with a `<style>` head
  only for the dark-mode media query and a mobile tweak (the one thing that
  cannot be inlined). So this module is deliberately self-contained and only
  borrows the brand hexes from `assets/css/app.css` for visual continuity.

  `render_to_string/2` is the entry point the chokepoint (`Vutuv.Notifications.Emailer`)
  calls; it renders a body template to a binary for `Swoosh.Email.html_body/2`.

  Note: inside `~H` a bare `@x` means `assigns.x`, so the shared palette lives in
  the `*_style/0` helpers below (plain functions, where module attributes work)
  and the templates call those, e.g. `style={p_style()}`.
  """
  use VutuvWeb, :html

  import VutuvWeb.UserHelpers

  alias Phoenix.HTML.Safe

  # Brand/slate palette, mirrored from assets/css/app.css @theme so HTML mail
  # looks like the product. Dark-mode counterparts live in the <style> block.
  @font "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"
  @mono "'SFMono-Regular',Menlo,Consolas,'Liberation Mono',monospace"

  @doc """
  Renders a body template (e.g. "login_email_en.html") to an HTML string.

  Mirrors `VutuvWeb.EmailText.render/2`. The `:html` macro already defines a
  private `render/2`, so this is named `render_to_string/2`. It dispatches to
  the `embed_templates`-generated function for the body and converts the
  rendered HEEx to a binary.
  """
  def render_to_string(template, assigns) do
    func = template |> String.trim_trailing(".html") |> String.to_existing_atom()

    __MODULE__
    |> apply(func, [Map.new(assigns)])
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  @doc """
  The email chrome shared by every message: document head (with the dark-mode
  and responsive `<style>`), a hidden preheader (inbox preview text), the
  brand-blue **vutuv** text wordmark, a white card holding the body
  (`:inner_block`), and the muted footer. Takes `locale` so the body can localize
  its own copy and signature; the footer is shared (matches `_footer.text.eex`).
  """
  attr(:preheader, :string, default: "vutuv")
  attr(:locale, :string, default: "en")
  slot(:inner_block, required: true)

  def email_layout(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang={@locale} xmlns="http://www.w3.org/1999/xhtml">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta http-equiv="x-ua-compatible" content="ie=edge" />
        <meta name="color-scheme" content="light dark" />
        <meta name="supported-color-schemes" content="light dark" />
        <title>vutuv</title>
        <style>
          body, .email-page { margin: 0 !important; padding: 0 !important; }
          table { border-collapse: collapse; }
          img { border: 0; outline: none; text-decoration: none; }
          a { color: #1d4ed8; }
          .preheader { display: none !important; }

          @media only screen and (max-width: 620px) {
            .email-container { width: 100% !important; max-width: 100% !important; }
            .email-card { padding: 24px !important; border-radius: 12px !important; }
          }

          @media (prefers-color-scheme: dark) {
            body, .email-page, .email-page > tbody > tr > td { background: #020617 !important; }
            .email-card { background: #0f172a !important; border-color: #1e293b !important; }
            .email-wordmark { color: #bfdbfe !important; }
            .email-h1 { color: #f1f5f9 !important; }
            .email-text, .email-text * { color: #cbd5e1 !important; }
            .email-muted, .email-muted * { color: #94a3b8 !important; }
            .email-a { color: #93c5fd !important; }
            .email-pin { background: #172554 !important; border-color: #1e3a8a !important; color: #dbeafe !important; }
            .email-panel { background: #0b1220 !important; border-color: #1e293b !important; }
            .email-divider td { border-color: #1e293b !important; }
            .email-footer, .email-footer a { color: #94a3b8 !important; }
          }
        </style>
      </head>
      <body class="email-page" style="margin:0;padding:0;width:100%;background:#f1f5f9;">
        <span class="preheader" style="display:none;max-height:0;overflow:hidden;mso-hide:all;font-size:1px;line-height:1px;color:#f1f5f9;opacity:0;">
          {@preheader}
        </span>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" class="email-page" style="background:#f1f5f9;">
          <tr>
            <td align="center" style="padding:24px 12px;">
              <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" class="email-container" style="width:600px;max-width:600px;">
                <tr>
                  <td align="center" style="padding:8px 8px 20px;">
                    <span class="email-wordmark" style={wordmark_style()}>vutuv</span>
                  </td>
                </tr>
                <tr>
                  <td class="email-card" style="background:#ffffff;border:1px solid #e2e8f0;border-radius:16px;padding:32px;">
                    {render_slot(@inner_block)}
                  </td>
                </tr>
                <tr>
                  <td class="email-footer" style={footer_style()}>
                    <p style="margin:0 0 2px;">vutuv is a service provided by Wintermeyer Consulting.
                      <a href="https://wintermeyer-consulting.de" style="color:#475569;">wintermeyer-consulting.de</a>
                    </p>
                    <p style="margin:0 0 2px;">Johannes-Müller-Str. 10 - 56068 Koblenz - Germany</p>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>
      </body>
    </html>
    """
  end

  @doc "A body paragraph."
  slot(:inner_block, required: true)

  def email_p(assigns) do
    ~H"""
    <p class="email-text" style={p_style()}>{render_slot(@inner_block)}</p>
    """
  end

  @doc "A prominent heading at the top of a card."
  slot(:inner_block, required: true)

  def email_heading(assigns) do
    ~H"""
    <h1 class="email-h1" style={h1_style()}>{render_slot(@inner_block)}</h1>
    """
  end

  @doc "The big monospace PIN / one-time-code box."
  attr(:pin, :string, required: true)

  def email_pin(assigns) do
    ~H"""
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 16px;">
      <tr>
        <td align="center" class="email-pin" style={pin_style()}>{@pin}</td>
      </tr>
    </table>
    """
  end

  @doc "A primary call-to-action button (a styled link)."
  attr(:href, :string, required: true)
  slot(:inner_block, required: true)

  def email_button(assigns) do
    ~H"""
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:4px 0 20px;">
      <tr>
        <td align="center" style="border-radius:8px;background:#1d4ed8;">
          <a href={@href} style={button_link_style()}>{render_slot(@inner_block)}</a>
        </td>
      </tr>
    </table>
    """
  end

  @doc "An inline link inside a paragraph or muted note."
  attr(:href, :string, required: true)
  slot(:inner_block, required: true)

  def email_link(assigns) do
    ~H"""
    <a href={@href} class="email-a" style="color:#1d4ed8;text-decoration:underline;">{render_slot(@inner_block)}</a>
    """
  end

  @doc "A boxed key/value panel; rows are `email_row/1`."
  slot(:inner_block, required: true)

  def email_panel(assigns) do
    ~H"""
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" class="email-panel" style="margin:0 0 16px;background:#f8fafc;border:1px solid #e2e8f0;border-radius:12px;">
      <tr>
        <td style="padding:6px 16px;">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
            {render_slot(@inner_block)}
          </table>
        </td>
      </tr>
    </table>
    """
  end

  @doc "A label/value row inside an `email_panel/1`."
  attr(:label, :string, required: true)
  slot(:inner_block, required: true)

  def email_row(assigns) do
    ~H"""
    <tr>
      <td class="email-muted" style={row_label_style()}>{@label}</td>
      <td class="email-text" style={row_value_style()}>{render_slot(@inner_block)}</td>
    </tr>
    """
  end

  @doc "A bulleted list, e.g. the security-alert reasons."
  attr(:items, :list, required: true)

  def email_list(assigns) do
    ~H"""
    <ul class="email-text" style={list_style()}>
      <li :for={item <- @items} style="margin:0 0 6px;">{item}</li>
    </ul>
    """
  end

  @doc "A hairline divider."
  def email_divider(assigns) do
    ~H"""
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" class="email-divider" style="margin:8px 0 20px;">
      <tr>
        <td style="border-top:1px solid #e2e8f0;font-size:0;line-height:0;height:1px;">&nbsp;</td>
      </tr>
    </table>
    """
  end

  @doc "Small print (the PS / unsubscribe lines)."
  slot(:inner_block, required: true)

  def email_muted(assigns) do
    ~H"""
    <p class="email-muted" style={muted_style()}>{render_slot(@inner_block)}</p>
    """
  end

  @doc "The localized closing signature (mirrors `_signature_<locale>.text.eex`)."
  attr(:locale, :string, default: "en")

  def email_signature(assigns) do
    ~H"""
    <p class="email-text" style={signature_style()}>
      {signature_line1(@locale)}<br />{signature_line2(@locale)}
    </p>
    """
  end

  defp signature_line1("de"), do: "Viele Grüße"
  defp signature_line1(_), do: "Regards"
  defp signature_line2("de"), do: "Ihr vutuv Team"
  defp signature_line2(_), do: "The vutuv team"

  @doc """
  The localized "switch these notification emails off here" footnote shared by
  every opt-out notification body (new follower, endorsement, unread messages).
  Wraps the tokenized one-click `unsubscribe_url` in an `email_muted`/`email_link`.
  """
  attr(:locale, :string, default: "en")
  attr(:unsubscribe_url, :string, required: true)

  def email_unsubscribe_note(%{locale: "de"} = assigns) do
    ~H"""
    <.email_muted>
      Diese Benachrichtigungs-E-Mails können Sie
      <.email_link href={@unsubscribe_url}>hier abschalten</.email_link>.
    </.email_muted>
    """
  end

  def email_unsubscribe_note(assigns) do
    ~H"""
    <.email_muted>
      You can switch these notification emails off
      <.email_link href={@unsubscribe_url}>here</.email_link>.
    </.email_muted>
    """
  end

  # Style strings, built here (where the @font/@mono module attributes work) and
  # called from the templates as `style={p_style()}` etc.
  defp wordmark_style,
    do: "font-family:#{@font};font-size:26px;font-weight:800;letter-spacing:-0.5px;color:#1d4ed8;"

  defp footer_style,
    do: "padding:20px 16px 4px;font-family:#{@font};font-size:12px;line-height:1.6;color:#475569;"

  defp p_style,
    do: "margin:0 0 16px;font-family:#{@font};font-size:16px;line-height:1.6;color:#334155;"

  defp h1_style,
    do:
      "margin:0 0 16px;font-family:#{@font};font-size:20px;line-height:1.4;font-weight:700;color:#0f172a;"

  defp pin_style,
    do:
      "padding:18px;background:#eff6ff;border:1px solid #dbeafe;border-radius:12px;font-family:#{@mono};font-size:30px;font-weight:700;letter-spacing:8px;color:#1e3a8a;"

  defp button_link_style,
    do:
      "display:inline-block;padding:12px 26px;font-family:#{@font};font-size:15px;font-weight:600;color:#ffffff;text-decoration:none;border-radius:8px;"

  defp row_label_style,
    do:
      "padding:6px 14px 6px 0;font-family:#{@font};font-size:14px;color:#64748b;vertical-align:top;"

  defp row_value_style,
    do: "padding:6px 0;font-family:#{@font};font-size:14px;color:#334155;word-break:break-word;"

  defp list_style,
    do:
      "margin:0 0 16px;padding-left:20px;font-family:#{@font};font-size:16px;line-height:1.6;color:#334155;"

  defp muted_style,
    do: "margin:0 0 16px;font-family:#{@font};font-size:13px;line-height:1.5;color:#64748b;"

  defp signature_style,
    do: "margin:24px 0 0;font-family:#{@font};font-size:16px;line-height:1.6;color:#334155;"

  embed_templates("../templates/email_body/*.html")
end
