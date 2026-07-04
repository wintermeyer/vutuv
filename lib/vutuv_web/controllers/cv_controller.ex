defmodule VutuvWeb.CVController do
  @moduledoc """
  The formatted CV (Lebenslauf) documents at `/:slug/export/cv/*`, issue
  #841: `preview` serves the print-ready HTML document inline (browser
  print dialog = the PDF path), `download` sends one of the file formats as
  an attachment.

  Public like the profile itself: every viewer gets the CV built from the
  data they may already see (`VutuvWeb.CV` resolves the email per viewer,
  so a private address only appears in the owner's own download), and the
  profile page links the formats for everyone. The one exception mirrors
  the agent docs: for a fully machine-opted-out member
  (`ContentPolicy.agent_docs_blocked?/1` — the same members whose
  `/:slug.json` 404s) the machine-readable JSON Resume answers 404 to
  everyone but the owner. The owner-only overview page (with the GDPR dump
  beside the CV) is `ExportController.index`.
  """

  use VutuvWeb, :controller

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

  def preview(conn, _params) do
    document =
      conn.assigns[:user]
      |> CV.build(viewer: conn.assigns[:current_user], photo: true)
      |> CV.Html.render(print_hint: true)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, document)
  end

  def download(conn, %{"format" => format}) when is_map_key(@content_types, format) do
    user = conn.assigns[:user]
    viewer = conn.assigns[:current_user]

    if format == "json" and machine_export_blocked?(user, viewer) do
      ControllerHelpers.render_error(conn, 404)
    else
      cv = CV.build(user, viewer: viewer, photo: format == "html")
      filename = "cv-#{user.username}-#{Date.utc_today()}.#{format}"

      send_download(conn, {:binary, render_format(format, cv)},
        filename: filename,
        content_type: Map.fetch!(@content_types, format)
      )
    end
  end

  def download(conn, _params), do: ControllerHelpers.render_error(conn, 404)

  defp machine_export_blocked?(user, viewer) do
    ContentPolicy.agent_docs_blocked?(user) and (is_nil(viewer) or viewer.id != user.id)
  end

  defp render_format("html", cv), do: CV.Html.render(cv)
  defp render_format("tex", cv), do: CV.Latex.render(cv)
  defp render_format("docx", cv), do: CV.Docx.render(cv)
  defp render_format("odt", cv), do: CV.Odt.render(cv)
  defp render_format("json", cv), do: CV.JsonResume.render(cv)
end
