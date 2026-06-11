defmodule VutuvWeb.ApiV1.SectionController do
  @moduledoc """
  The profile sections over the API.

  Reads: `GET /api/v1/users/:slug/<section>` — the same doc maps the public
  `.json` section pages serve, with one viewer-dependent exception: the
  email list shows what the viewer would see on the page (public addresses,
  or all of them for the owner / when the owner follows the viewer).

  Writes: `POST /api/v1/me/<section>`, `PATCH`/`DELETE
  /api/v1/me/<section>/:id` — always on the authorized user's own entries,
  through the same changesets as the HTML forms. Emails are read-only here
  (an address is a PIN-verified identity, issue #759); tags have their own
  controller (`VutuvWeb.ApiV1.TagController`).

  Which section a route means comes from the route's `assigns: %{section:
  …}` in the router.
  """

  use VutuvWeb, :controller

  alias Vutuv.Profiles.{Address, PhoneNumber, SocialMediaAccount, Url, WorkExperience}
  alias Vutuv.Tags.UserTag
  alias Vutuv.UUIDv7
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ApiV1
  alias VutuvWeb.ApiV1.Problem
  alias VutuvWeb.UserHelpers

  plug(VutuvWeb.Plug.RequireScope, "profile:read" when action == :index)

  plug(
    VutuvWeb.Plug.RequireScope,
    "profile:write" when action in [:create, :update, :delete]
  )

  @writable %{
    work_experiences: %{assoc: :work_experiences, schema: WorkExperience},
    links: %{assoc: :urls, schema: Url},
    social_media_accounts: %{assoc: :social_media_accounts, schema: SocialMediaAccount},
    addresses: %{assoc: :addresses, schema: Address},
    phone_numbers: %{assoc: :phone_numbers, schema: PhoneNumber}
  }

  def index(conn, %{"slug" => slug}) do
    viewer = conn.assigns.current_user
    section = conn.assigns.section

    case ApiV1.fetch_visible_user(slug, viewer) do
      {:ok, user} ->
        doc = SectionDocs.build_index(user, section, entries(user, section, viewer))
        ApiV1.send_json(conn, doc)

      :error ->
        Problem.not_found(conn)
    end
  end

  def create(conn, params) do
    %{assoc: assoc, schema: schema} = Map.fetch!(@writable, conn.assigns.section)
    user = conn.assigns.current_user

    changeset = user |> build_assoc(assoc) |> schema.changeset(params)

    case Repo.insert(changeset) do
      {:ok, record} ->
        after_create(conn.assigns.section, record)
        ApiV1.send_json(conn, SectionDocs.build_show(user, conn.assigns.section, record), 201)

      {:error, changeset} ->
        Problem.validation_failed(conn, changeset)
    end
  end

  def update(conn, %{"id" => id} = params) do
    %{assoc: assoc, schema: schema} = Map.fetch!(@writable, conn.assigns.section)
    user = conn.assigns.current_user

    with %{} = record <- get_owned(user, assoc, id),
         {:ok, record} <- record |> schema.changeset(params) |> Repo.update() do
      ApiV1.send_json(conn, SectionDocs.build_show(user, conn.assigns.section, record))
    else
      nil -> Problem.not_found(conn)
      {:error, changeset} -> Problem.validation_failed(conn, changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    %{assoc: assoc} = Map.fetch!(@writable, conn.assigns.section)

    case get_owned(conn.assigns.current_user, assoc, id) do
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

  defp entries(user, section, _viewer) do
    Repo.all(assoc(user, Map.fetch!(@writable, section).assoc))
  end

  # Same side effect as the HTML link form: capture the page screenshot off
  # the request path, supervised, gated so tests launch no Chromium.
  defp after_create(:links, url) do
    if Application.get_env(:vutuv, :generate_screenshots, true) do
      Task.Supervisor.start_child(Vutuv.TaskSupervisor, fn ->
        Vutuv.PageScreenshot.generate_screenshot(url)
      end)
    end

    :ok
  end

  defp after_create(_section, _record), do: :ok

  defp get_owned(user, assoc_name, id) do
    case UUIDv7.cast_or_nil(id) do
      nil -> nil
      uuid -> Repo.get(assoc(user, assoc_name), uuid)
    end
  end
end
