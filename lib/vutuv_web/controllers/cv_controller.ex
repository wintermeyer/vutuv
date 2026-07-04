defmodule VutuvWeb.CVController do
  @moduledoc """
  The formatted CV (Lebenslauf) documents at `/:slug/export/cv/*`, issue
  #841: `preview` serves the print-ready HTML document inline (browser
  print dialog = the PDF path), `download` sends one of the file formats as
  an attachment. The offering page is `ExportController.index`
  (`/:slug/export`), where the CV sits beside the GDPR data dump.

  Owner-only like that page: `AuthUser` on top of the `:user_pipe`-resolved
  `:user` — a CV bundles contact details, so nobody downloads someone
  else's.
  """

  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.RequireLogin)
  plug(VutuvWeb.Plug.AuthUser)

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
      |> CV.build(photo: true)
      |> CV.Html.render(print_hint: true)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, document)
  end

  def download(conn, %{"format" => format}) when is_map_key(@content_types, format) do
    user = conn.assigns[:user]
    cv = CV.build(user, photo: format == "html")
    filename = "cv-#{user.username}-#{Date.utc_today()}.#{format}"

    send_download(conn, {:binary, render_format(format, cv)},
      filename: filename,
      content_type: Map.fetch!(@content_types, format)
    )
  end

  def download(conn, _params), do: ControllerHelpers.render_error(conn, 404)

  defp render_format("html", cv), do: CV.Html.render(cv)
  defp render_format("tex", cv), do: CV.Latex.render(cv)
  defp render_format("docx", cv), do: CV.Docx.render(cv)
  defp render_format("odt", cv), do: CV.Odt.render(cv)
  defp render_format("json", cv), do: CV.JsonResume.render(cv)
end
