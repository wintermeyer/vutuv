defmodule VutuvWeb.ImportController do
  @moduledoc """
  Import a member's own profile from a LinkedIn data-export ZIP: upload the
  archive, preview what was found (deselect anything), then create the picks.

  Owner-only, guarded exactly like the settings pages (`UserResolveSlug` +
  `AuthUser` + `EnsureActivated`). The preview → confirm step is stateless: the
  parsed candidates ride in a hidden field, because the cookie session is too
  small to hold a heavy export (see `Vutuv.Imports.LinkedIn`).
  """
  use VutuvWeb, :controller

  require Logger

  # Routed under /settings: the pipeline (RequireLogin + SettingsUser +
  # EnsureActivated) provides :user = the logged-in member; AuthUser stays as
  # a belt-and-braces guard.
  plug(VutuvWeb.Plug.AuthUser)
  # After the auth plugs, so a non-owner 403s (and is never counted). Throttles
  # the decompress/parse (create) and the DB write (confirm), per member + IP.
  plug(:rate_limit when action in [:create, :confirm])

  alias Vutuv.Imports.LinkedIn
  alias VutuvWeb.RateLimit

  # LinkedIn's "larger data archive" runs to tens of megabytes for an active
  # account (message dumps ride along), so allow a generous upload — the parse
  # only ever inflates the small CSVs. Keep this below the multipart :length
  # in the endpoint (64 MB), or the friendly too-large flash can never fire.
  @max_upload_bytes 50_000_000

  def new(conn, _params) do
    render(conn, "new.html",
      user: conn.assigns[:user],
      max_upload_bytes: @max_upload_bytes,
      page_title: gettext("Import from LinkedIn")
    )
  end

  def create(conn, %{"import" => %{"archive" => %Plug.Upload{} = upload}}) do
    user = conn.assigns[:user]

    result = parse_upload(upload)

    # Delete the uploaded temp file the moment we've read it. Plug also sweeps it
    # when the request process exits, but the archive holds the member's personal
    # data, so drop it eagerly. There is nothing else on disk to clean up: the
    # CSVs are only ever decompressed into memory (`:zip.unzip [:memory]`), never
    # written out, so they vanish with the request's garbage collection.
    _ = File.rm(upload.path)

    case result do
      {:ok, parsed} ->
        render_preview(conn, user, parsed)

      {:error, :too_large} ->
        redirect_with_error(
          conn,
          user,
          gettext("That file is too large. Please upload a ZIP of at most 50 MB.")
        )

      {:error, :archive_too_large} ->
        redirect_with_error(
          conn,
          user,
          gettext("That archive is too large or has too many files to import safely.")
        )

      {:error, :invalid_archive} ->
        redirect_with_error(
          conn,
          user,
          gettext("That does not look like a LinkedIn data export ZIP.")
        )
    end
  end

  def create(conn, _params) do
    user = conn.assigns[:user]
    redirect_with_error(conn, user, gettext("Please choose your LinkedIn export ZIP first."))
  end

  def confirm(conn, %{"payload" => payload} = params) do
    user = conn.assigns[:user]
    selected = Map.get(params, "selected", [])

    with {:ok, decoded} <- Jason.decode(payload),
         selection = LinkedIn.selection_from_payload(decoded, selected),
         {:ok, summary} <- LinkedIn.apply_selection(user, selection) do
      conn
      |> put_flash(:info, summary_flash(summary))
      |> redirect(to: ~p"/#{user}")
    else
      _ ->
        redirect_with_error(
          conn,
          user,
          gettext("The import could not be completed. Please try again.")
        )
    end
  end

  # The parse itself is fully rescued inside LinkedIn, but the preview
  # assembly after it (duplicate marking, the payload JSON) was the one
  # stretch of the upload flow that could still raise — and did, on a CSV a
  # member had re-saved in a non-UTF-8 encoding. Whatever an archive does, the
  # member gets a flash and the form back, never the 500 page.
  defp render_preview(conn, user, parsed) do
    render(conn, "preview.html",
      user: user,
      candidates: LinkedIn.mark_duplicates(user, parsed),
      payload: Jason.encode!(LinkedIn.payload_map(parsed)),
      page_title: gettext("Import from LinkedIn")
    )
  rescue
    error ->
      Logger.error(
        "LinkedIn import preview failed: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      redirect_with_error(conn, user, gettext("The file could not be read. Please try again."))
  end

  defp parse_upload(upload) do
    with :ok <- within_size_limit(upload) do
      LinkedIn.parse_file(upload.path)
    end
  end

  defp rate_limit(conn, _opts) do
    case RateLimit.check_linkedin_import(conn, conn.assigns[:user]) do
      :ok ->
        conn

      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many imports. Please try again in a little while."))
        |> redirect(to: ~p"/settings/import/linkedin")
        |> halt()
    end
  end

  defp within_size_limit(%Plug.Upload{path: path}) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_upload_bytes -> :ok
      _ -> {:error, :too_large}
    end
  end

  defp redirect_with_error(conn, _user, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/settings/import/linkedin")
  end

  # "Imported 1 work experience, 2 tags. Skipped 3 entries …". The skip reason
  # names both cases: an entry the member already has AND one another member
  # has claimed (the globally-unique social handles — see
  # LinkedIn.social_key_unless_claimed/1).
  defp summary_flash(summary) do
    summary.created
    |> imported_parts()
    |> imported_message()
    |> append_skipped(skipped_total(summary.skipped))
  end

  defp imported_parts(created) do
    [
      created.positions > 0 &&
        ngettext("%{count} work experience", "%{count} work experiences", created.positions),
      created.educations > 0 &&
        ngettext("%{count} education entry", "%{count} education entries", created.educations),
      created.certifications > 0 &&
        ngettext(
          "%{count} certificate or license",
          "%{count} certificates or licenses",
          created.certifications
        ),
      created.skills > 0 && ngettext("%{count} tag", "%{count} tags", created.skills),
      created.urls > 0 && ngettext("%{count} link", "%{count} links", created.urls),
      created.social > 0 &&
        ngettext("%{count} social account", "%{count} social accounts", created.social),
      created.phones > 0 &&
        ngettext("%{count} phone number", "%{count} phone numbers", created.phones),
      created.profile != [] &&
        ngettext("%{count} profile field", "%{count} profile fields", length(created.profile))
    ]
    |> Enum.filter(& &1)
  end

  defp imported_message([]), do: gettext("Nothing new to import.")
  defp imported_message(parts), do: gettext("Imported %{items}.", items: Enum.join(parts, ", "))

  defp skipped_total(skipped) do
    skipped.positions + skipped.educations + skipped.certifications + skipped.skills +
      skipped.urls + skipped.social + skipped.phones
  end

  defp append_skipped(message, 0), do: message

  defp append_skipped(message, count) do
    message <>
      " " <>
      ngettext(
        "Skipped %{count} entry that is already on your profile or taken by another member.",
        "Skipped %{count} entries that are already on your profile or taken by another member.",
        count
      )
  end
end
