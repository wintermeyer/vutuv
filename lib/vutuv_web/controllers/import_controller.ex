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
      # Which import ran, never what came in: the entries are on the profile
      # already, and the archive's contents are none of the log's business.
      Vutuv.AccountEvents.record(user, "import_applied",
        conn: conn,
        details: %{source: "linkedin"}
      )

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
    candidates = LinkedIn.mark_duplicates(user, parsed)

    render(conn, "preview.html",
      user: user,
      candidates: candidates,
      # Display only, so it stays out of the hidden payload: the confirm step
      # must not be able to read counts back from a client-controlled field.
      summary: LinkedIn.summary_rows(candidates),
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

  # "Imported 1 work experience, 2 tags. Skipped 3 entries that are already on
  # your profile. 1 social account is already claimed by another member."
  #
  # The two not-created reasons are told apart because they mean opposite
  # things to the member: a skipped entry is on the profile already, a blocked
  # one never landed. One sentence for both said "already on your profile"
  # about entries that were not.
  defp summary_flash(summary) do
    [
      summary.created |> imported_parts() |> imported_message(),
      skipped_sentence(total(summary.skipped))
      | blocked_sentences(summary.blocked)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
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

  defp total(tally), do: tally |> Map.values() |> Enum.sum()

  defp skipped_sentence(0), do: nil

  defp skipped_sentence(count) do
    ngettext(
      "Skipped %{count} entry that is already on your profile.",
      "Skipped %{count} entries that are already on your profile.",
      count
    )
  end

  # A claimed social handle is the one blocked case with an explanation the
  # member can act on (social_media_accounts has a GLOBAL unique index on
  # provider + value), so it gets its own sentence; anything else is a value
  # the schema refused and is reported plainly rather than guessed at.
  defp blocked_sentences(blocked) do
    [claimed_sentence(blocked.social), rejected_sentence(total(blocked) - blocked.social)]
  end

  defp claimed_sentence(0), do: nil

  defp claimed_sentence(count) do
    ngettext(
      "%{count} social account could not be added because another member has already claimed it.",
      "%{count} social accounts could not be added because another member has already claimed them.",
      count
    )
  end

  defp rejected_sentence(0), do: nil

  defp rejected_sentence(count) do
    ngettext("%{count} entry could not be added.", "%{count} entries could not be added.", count)
  end
end
