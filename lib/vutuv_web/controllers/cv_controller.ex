defmodule VutuvWeb.CVController do
  @moduledoc """
  The formatted CV (Lebenslauf) at `/:slug/cv`, issue #841. `show` embeds the
  interactive builder `VutuvWeb.CVLive` (via `live_render/3`, the profile's
  pattern); `print` serves the print-ready HTML document inline (the PDF path
  = the browser's print dialog); `download` sends one of the file formats as
  an attachment.

  Public like the profile: every viewer gets the CV built from the data they
  may already see (`VutuvWeb.CV` resolves the email per viewer, so a private
  address only appears in the owner's own download). All three actions honor
  the builder's `?hide=<keys>` selection — a comma-separated set of identity
  fields, section keys and entry ids to leave out — so a shared/anonymized
  link carries its trimming. Every download format, JSON Resume included, is
  offered to every viewer: they all render the same public CV a member chose
  to export, so none is gated (the profile's agent-doc opt-out governs
  crawler access to the profile, not a member-initiated CV download).

  The owner-only GDPR data dump keeps its own home at `/:slug/export`
  (`ExportController`).
  """

  use VutuvWeb, :controller

  import Phoenix.LiveView.Controller, only: [live_render: 3]

  alias VutuvWeb.ContentPolicy
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.CV

  @content_types %{
    "html" => "text/html",
    "tex" => "application/x-tex",
    "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "odt" => "application/vnd.oasis.opendocument.text",
    "json" => "application/json"
  }

  def show(conn, _params) do
    user = conn.assigns[:user]

    conn
    |> ContentPolicy.put_robots_header(user.noindex?, user.noai?)
    |> put_layout(html: false)
    |> live_render(VutuvWeb.CVLive,
      session: Map.put(ControllerHelpers.live_render_session(conn), "profile_user_id", user.id)
    )
  end

  def print(conn, params) do
    document =
      conn.assigns[:user]
      |> CV.build(viewer: conn.assigns[:current_user], photo: true)
      |> CV.apply_hide(parse_hide(params))
      |> CV.Html.render(print_hint: true)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, document)
  end

  def download(conn, %{"format" => format} = params) when is_map_key(@content_types, format) do
    user = conn.assigns[:user]
    viewer = conn.assigns[:current_user]
    hide = parse_hide(params)
    cv = user |> CV.build(viewer: viewer, photo: format == "html") |> CV.apply_hide(hide)

    send_download(conn, {:binary, render_format(format, cv)},
      filename: filename(user, hide, format),
      content_type: Map.fetch!(@content_types, format)
    )
  end

  def download(conn, _params), do: ControllerHelpers.render_error(conn, 404)

  # A comma-separated list of hide-keys (identity fields / section keys /
  # entry ids); only ever removes data, so no validation beyond splitting.
  defp parse_hide(params) do
    (params["hide"] || "")
    |> String.split(",", trim: true)
    |> MapSet.new()
  end

  # An anonymized CV (name hidden) drops the username from the filename too.
  defp filename(user, hide, format) do
    if MapSet.member?(hide, "name"),
      do: "cv-#{Date.utc_today()}.#{format}",
      else: "cv-#{user.username}-#{Date.utc_today()}.#{format}"
  end

  defp render_format("html", cv), do: CV.Html.render(cv)
  defp render_format("tex", cv), do: CV.Latex.render(cv)
  defp render_format("docx", cv), do: CV.Docx.render(cv)
  defp render_format("odt", cv), do: CV.Odt.render(cv)
  defp render_format("json", cv), do: CV.JsonResume.render(cv)
end
