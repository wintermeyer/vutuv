defmodule VutuvWeb.ApiV2.SectionController do
  @moduledoc """
  The profile sections over the API.

  Reads: `GET /api/2.0/users/:slug/<section>` — the same doc maps the public
  `.json` section pages serve, with one viewer-dependent exception: the
  email list shows what the viewer would see on the page (public addresses,
  or all of them for the owner / when the owner follows the viewer).

  Writes: `POST /api/2.0/me/<section>`, `PATCH`/`DELETE
  /api/2.0/me/<section>/:id` — always on the authorized user's own entries,
  through the same changesets as the HTML forms. Emails are read-only here
  (an address is a PIN-verified identity, issue #759); tags have their own
  controller (`VutuvWeb.ApiV2.TagController`).

  Which section a route means comes from the route's `assigns: %{section:
  …}` in the router.
  """

  use VutuvWeb, :controller

  alias Vutuv.Profiles.{
    Address,
    Language,
    PhoneNumber,
    Qualification,
    SocialMediaAccount,
    Url,
    WorkExperience
  }

  alias Vutuv.Tags.UserTag
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ApiV2
  alias VutuvWeb.ApiV2.Problem
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.UserHelpers

  @writable %{
    work_experiences: %{assoc: :work_experiences, schema: WorkExperience},
    links: %{assoc: :urls, schema: Url},
    social_media_accounts: %{assoc: :social_media_accounts, schema: SocialMediaAccount},
    addresses: %{assoc: :addresses, schema: Address},
    phone_numbers: %{assoc: :phone_numbers, schema: PhoneNumber},
    languages: %{assoc: :languages, schema: Language},
    qualifications: %{assoc: :qualifications, schema: Qualification}
  }

  def index(conn, %{"slug" => slug}) do
    viewer = conn.assigns.current_user
    section = conn.assigns.section

    ApiV2.with_visible_user(conn, slug, fn user ->
      doc = SectionDocs.build_index(user, section, entries(user, section, viewer))
      ApiV2.send_json(conn, doc)
    end)
  end

  def create(conn, params) do
    %{assoc: assoc, schema: schema} = Map.fetch!(@writable, conn.assigns.section)
    user = conn.assigns.current_user

    changeset = user |> build_assoc(assoc) |> schema.changeset(params)

    case Repo.insert(changeset) do
      {:ok, record} ->
        after_write(conn.assigns.section, record)
        ApiV2.send_json(conn, SectionDocs.build_show(user, conn.assigns.section, record), 201)

      {:error, changeset} ->
        Problem.validation_failed(conn, changeset)
    end
  end

  def update(conn, %{"id" => id} = params) do
    %{assoc: assoc, schema: schema} = Map.fetch!(@writable, conn.assigns.section)
    user = conn.assigns.current_user

    with %{} = record <- ControllerHelpers.get_owned(user, assoc, id),
         {:ok, record} <- record |> schema.changeset(params) |> Repo.update() do
      after_write(conn.assigns.section, record)
      ApiV2.send_json(conn, SectionDocs.build_show(user, conn.assigns.section, record))
    else
      nil -> Problem.not_found(conn)
      {:error, changeset} -> Problem.validation_failed(conn, changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    %{assoc: assoc} = Map.fetch!(@writable, conn.assigns.section)

    case ControllerHelpers.get_owned(conn.assigns.current_user, assoc, id) do
      nil ->
        Problem.not_found(conn)

      record ->
        Repo.delete!(record)
        send_resp(conn, 204, "")
    end
  end

  # The email list is the one viewer-dependent section (see moduledoc).
  defp entries(user, :emails, viewer), do: UserHelpers.emails_for_display(user, viewer)

  defp entries(user, :tags, _viewer) do
    Repo.all(from(ut in UserTag.ordered_by_endorsements(), where: ut.user_id == ^user.id))
    |> Repo.preload(:tag)
  end

  # Work experiences carry no `position` (they sort by date elsewhere); keep
  # their existing order so only the position-bearing sections get reordered.
  defp entries(user, :work_experiences, _viewer) do
    Repo.all(assoc(user, :work_experiences))
  end

  # The position-ordered sections (links, social, addresses, phone numbers)
  # follow the owner's chosen order, matching the HTML pages.
  defp entries(user, section, _viewer) do
    %{assoc: assoc, schema: schema} = Map.fetch!(@writable, section)
    Repo.all(schema.ordered(assoc(user, assoc)))
  end

  # Same side effect as the HTML link forms (create AND update, so an API edit
  # never leaves a stale screenshot); shares the supervised, gated capture.
  defp after_write(:links, url), do: Vutuv.PageScreenshot.generate_async(url)

  defp after_write(_section, _record), do: :ok
end
