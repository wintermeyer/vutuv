defmodule VutuvWeb.QualificationDocumentController do
  @moduledoc """
  The authorizing proxy for a qualification's proof document
  (`Vutuv.QualificationDocument`): the thumbnail (`thumb-<fp>.avif`) and the
  downloadable public copy (`<fp>.<ext>`), both under
  `/:slug/qualifications/:id/document/`.

  Access policy: the document must exist, the URL's fingerprint must match the
  stored one (the URL names the bytes, and a browser holding them revalidates
  rather than re-fetching, so a stale fingerprint must 404 rather than be
  served), and while the AI image scan still holds it in limbo
  only the owner gets the bytes (the review-cover pattern: no quarantine tree,
  the proxy checks the moderation state). Everything else — unknown ids, wrong
  fingerprints, a pending document to a visitor — is the same 404, so the
  proxy never leaks whether a document exists.

  The public copy serves `inline` (a click on the thumbnail opens the PDF or
  image in the browser) with the member's original filename as the save-as
  name; `?dl=1` switches to `attachment` — the show page's explicit
  "Download" affordance.
  """

  use VutuvWeb, :controller

  alias Vutuv.Profiles.Qualification
  alias Vutuv.QualificationDocument
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.ImageProxy

  def show(conn, %{"id" => id, "file" => file}) do
    with %Qualification{} = qualification <-
           ControllerHelpers.get_owned(conn.assigns[:user], :qualifications, id),
         true <- Qualification.document?(qualification),
         true <- visible_to?(qualification, conn.assigns[:current_user]),
         {:ok, kind} <- parse_file(file, qualification) do
      serve(conn, qualification, kind)
    else
      _ -> ImageProxy.not_found(conn)
    end
  end

  # Only the two expected names resolve, each carrying the current
  # fingerprint; anything else (including "original.*" or a stale
  # fingerprint) is a 404.
  defp parse_file(file, qualification) do
    fingerprint = qualification.document_fingerprint

    cond do
      is_nil(fingerprint) -> :error
      file == "thumb-#{fingerprint}.avif" -> {:ok, :thumb}
      file == "#{fingerprint}#{public_ext(qualification)}" -> {:ok, :file}
      true -> :error
    end
  end

  defp visible_to?(qualification, viewer) do
    Qualification.document_released?(qualification) or
      (viewer != nil and viewer.id == qualification.user_id)
  end

  defp serve(conn, qualification, :thumb) do
    send_document(conn, QualificationDocument.thumb_path(qualification.id), fn conn -> conn end)
  end

  defp serve(conn, qualification, :file) do
    disposition = if conn.params["dl"] == "1", do: "attachment", else: "inline"

    send_document(conn, QualificationDocument.file_path(qualification.id), fn conn ->
      put_resp_header(
        conn,
        "content-disposition",
        "#{disposition}; #{disposition_filename(qualification)}"
      )
    end)
  end

  defp send_document(conn, nil, _decorate), do: ImageProxy.not_found(conn)

  defp send_document(conn, path, decorate) do
    ImageProxy.send_version(conn, path, decorate: fn conn, _ext -> decorate.(conn) end)
  end

  # The save-as name is the member's original filename; the RFC 5987 pair that
  # carries it lives in `VutuvWeb.ControllerHelpers`.
  defp disposition_filename(qualification),
    do: qualification |> safe_filename() |> ControllerHelpers.disposition_filename()

  # The stored client filename, its extension normalized to the public copy's
  # (a HEIC upload downloads as JPEG).
  defp safe_filename(qualification) do
    base = qualification.document |> Path.basename() |> Path.rootname()
    base <> public_ext(qualification)
  end

  defp public_ext(qualification),
    do: QualificationDocument.public_ext(qualification.document_content_type)
end
