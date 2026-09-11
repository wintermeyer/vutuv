defmodule VutuvWeb.JobReferenceDocumentController do
  @moduledoc """
  The authorizing proxy for an uploaded Arbeitszeugnis
  (`Vutuv.JobReferenceDocument`): the two derived previews
  (`thumb-<fp>.avif`, `page-<fp>.avif`) and the downloadable copy
  (`<fp>.<ext>`), all under `/:slug/job_references/:id/document/`.

  The access rule is stricter than the qualification proxy it mirrors, and the
  difference is the whole point of this module: a proof document is public the
  moment it is stored, while a Zeugnis is **private by default**. So three
  things must all hold before any byte leaves: the entry is published, the
  document cleared moderation, and the URL's fingerprint matches what is
  stored. The owner bypasses the first two, and nobody bypasses the third —
  the URL names the bytes, and a browser holding them revalidates rather than
  re-fetching, so a stale fingerprint must 404 rather than be served.

  Every refusal is the same 404, so the proxy never reveals whether a private
  Zeugnis exists at a given id.
  """

  use VutuvWeb, :controller

  alias Vutuv.JobReferenceDocument
  alias Vutuv.References.JobReference
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.ImageProxy

  def show(conn, %{"id" => id, "file" => file}) do
    with %JobReference{} = reference <-
           ControllerHelpers.get_owned(conn.assigns[:user], :job_references, id),
         true <- JobReference.document?(reference),
         true <- visible_to?(reference, conn.assigns[:current_user]),
         {:ok, kind} <- parse_file(file, reference) do
      serve(conn, reference, kind)
    else
      _refused -> ImageProxy.not_found(conn)
    end
  end

  # Only the three expected names resolve, each carrying the current
  # fingerprint; anything else (including "original.*" or a stale fingerprint)
  # is a 404.
  defp parse_file(file, reference) do
    fingerprint = reference.document_fingerprint

    cond do
      is_nil(fingerprint) -> :error
      file == "thumb-#{fingerprint}.avif" -> {:ok, :thumb}
      file == "page-#{fingerprint}.avif" -> {:ok, :page}
      file == "#{fingerprint}#{public_ext(reference)}" -> {:ok, :file}
      true -> :error
    end
  end

  # The owner always sees their own file, published or not — this is also the
  # preview on their editor page. Everyone else needs both gates.
  defp visible_to?(reference, viewer) do
    JobReference.publicly_visible?(reference) or
      (viewer != nil and viewer.id == reference.user_id)
  end

  defp serve(conn, reference, version) when version in [:thumb, :page] do
    send_document(
      conn,
      JobReferenceDocument.version_path(reference.id, version),
      fn conn -> conn end
    )
  end

  defp serve(conn, reference, :file) do
    disposition = if conn.params["dl"] == "1", do: "attachment", else: "inline"

    send_document(conn, JobReferenceDocument.file_path(reference.id), fn conn ->
      put_resp_header(
        conn,
        "content-disposition",
        "#{disposition}; #{disposition_filename(reference)}"
      )
    end)
  end

  defp send_document(conn, nil, _decorate), do: ImageProxy.not_found(conn)

  defp send_document(conn, path, decorate) do
    ImageProxy.send_version(conn, path, decorate: fn conn, _ext -> decorate.(conn) end)
  end

  # The save-as name is the member's original filename; the RFC 5987 pair that
  # keeps a "Zeugnis Müller.pdf" intact lives in `VutuvWeb.ControllerHelpers`.
  defp disposition_filename(reference),
    do: reference |> safe_filename() |> ControllerHelpers.disposition_filename()

  defp safe_filename(reference) do
    base = reference.document |> Path.basename() |> Path.rootname()
    base <> public_ext(reference)
  end

  defp public_ext(reference),
    do: JobReferenceDocument.public_ext(reference.document_content_type)
end
