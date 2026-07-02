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

  plug(VutuvWeb.Plug.UserResolveSlug)
  plug(VutuvWeb.Plug.AuthUser)
  plug(VutuvWeb.Plug.EnsureActivated)
  # After the auth plugs, so a non-owner 403s (and is never counted). Throttles
  # the decompress/parse (create) and the DB write (confirm), per member + IP.
  plug(:rate_limit when action in [:create, :confirm])

  alias Vutuv.Imports.LinkedIn
  alias VutuvWeb.RateLimit

  # A LinkedIn export is a handful of small CSVs; cap the upload so a huge file
  # can't be posted here.
  @max_upload_bytes 20_000_000

  def new(conn, _params) do
    render(conn, "new.html",
      user: conn.assigns[:user],
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
        render(conn, "preview.html",
          user: user,
          candidates: LinkedIn.mark_duplicates(user, parsed),
          payload: Jason.encode!(LinkedIn.payload_map(parsed)),
          page_title: gettext("Import from LinkedIn")
        )

      {:error, :too_large} ->
        redirect_with_error(
          conn,
          user,
          gettext("That file is too large. A LinkedIn export is only a few megabytes.")
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

      _ ->
        redirect_with_error(conn, user, gettext("The file could not be read. Please try again."))
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

  defp parse_upload(upload) do
    with :ok <- within_size_limit(upload),
         {:ok, binary} <- File.read(upload.path) do
      LinkedIn.parse(binary)
    end
  end

  defp rate_limit(conn, _opts) do
    case RateLimit.check_linkedin_import(conn, conn.assigns[:user]) do
      :ok ->
        conn

      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many imports. Please try again in a little while."))
        |> redirect(to: ~p"/#{conn.assigns[:user]}/settings/import/linkedin")
        |> halt()
    end
  end

  defp within_size_limit(%Plug.Upload{path: path}) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_upload_bytes -> :ok
      _ -> {:error, :too_large}
    end
  end

  defp redirect_with_error(conn, user, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/#{user}/settings/import/linkedin")
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
    skipped.positions + skipped.educations + skipped.skills + skipped.urls + skipped.social +
      skipped.phones
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
