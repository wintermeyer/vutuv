defmodule VutuvWeb.ApiV2.JobController do
  @moduledoc """
  Job postings over the API (issue #936) — the second door to the same room as
  the `/jobs` forms. Every write runs through the exact `Vutuv.Jobs` changesets
  and policies (the 90-day lifecycle, the anti-abuse gate, organization
  attribution only with a role, the salary/AGG/location validations), so an API
  posting is indistinguishable from a form posting and fires the same
  `job.published` webhook.

  Reads (`jobs:read`): `GET /jobs` (the viewer-scoped board, cursor-paginated,
  the same filters as `/jobs`), `GET /jobs/:id` (one posting — the owner sees any
  state, a stranger only a live published one). Writes (`jobs:write`, own
  postings only): `POST /jobs` (create a draft, or `publish: true` to go live in
  one call), `PATCH /jobs/:id` (edit, or publish a draft), `POST /jobs/:id/closure`
  (close with `filled`/`withdrawn`), `DELETE /jobs/:id` (discard a draft).
  """

  use VutuvWeb, :controller

  alias Vutuv.Jobs
  alias Vutuv.Jobs.JobPosting
  alias Vutuv.Organizations
  alias Vutuv.UUIDv7
  alias VutuvWeb.AgentDocs.JobPostingDoc
  alias VutuvWeb.ApiV2
  alias VutuvWeb.ApiV2.Problem

  # ── Reads ──

  def index(conn, params) do
    viewer = conn.assigns.current_user

    ApiV2.with_cursor(conn, params, fn cursor ->
      filters = Jobs.board_filters(normalize_filters(params), viewer)
      page = Jobs.board_page(viewer, filters, cursor: cursor, limit: ApiV2.page_limit(params))

      doc = %{
        type: "jobs",
        jobs: Enum.map(page.entries, &JobPostingDoc.api_summary/1),
        more: page.more?,
        next_cursor: ApiV2.encode_cursor(page.more? && page.cursor)
      }

      ApiV2.send_json(conn, doc)
    end)
  end

  def show(conn, %{"id" => id}) do
    case fetch_readable_job(id, conn.assigns.current_user) do
      {:ok, posting} -> ApiV2.send_json(conn, JobPostingDoc.api_show(posting))
      :error -> Problem.not_found(conn)
    end
  end

  # ── Writes ──

  def create(conn, params) do
    user = conn.assigns.current_user

    case resolve_organization(Map.get(params, "organization"), user) do
      {:ok, organization} -> do_create(conn, user, params, organization)
      {:error, reason} -> organization_error(conn, reason)
    end
  end

  defp do_create(conn, user, params, organization) do
    if truthy(params["publish"]) do
      create_and_publish(conn, user, params, organization)
    else
      case Jobs.create_draft(user, params, organization: organization) do
        {:ok, posting} -> ApiV2.send_json(conn, JobPostingDoc.api_show(posting), 201)
        {:error, %Ecto.Changeset{} = changeset} -> Problem.validation_failed(conn, changeset)
      end
    end
  end

  # POST /jobs with publish:true is atomic — a failed publish deletes the draft
  # so there is never an orphan; the client gets a published posting or a clean
  # error and nothing created.
  defp create_and_publish(conn, user, params, organization) do
    case Jobs.create_draft(user, params, organization: organization) do
      {:error, %Ecto.Changeset{} = changeset} ->
        Problem.validation_failed(conn, changeset)

      {:ok, draft} ->
        case Jobs.publish(draft, user, params, organization: organization) do
          {:ok, posting} ->
            ApiV2.send_json(conn, JobPostingDoc.api_show(posting), 201)

          {:error, reason} ->
            Jobs.delete_job_posting(draft)
            publish_error(conn, reason)
        end
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    case fetch_own_job(id, user) do
      {:ok, posting} -> do_update(conn, posting, user, params)
      :error -> Problem.not_found(conn)
    end
  end

  defp do_update(conn, posting, user, params) do
    cond do
      Jobs.effective_status(posting) in [:expired, :closed] ->
        Problem.send_problem(conn, 409, "Not editable",
          detail: "An expired or closed posting cannot be edited or reopened — repost instead.",
          extra: %{reason: :not_editable}
        )

      posting.status == :draft and truthy(params["publish"]) ->
        publish_draft(conn, posting, user, params)

      true ->
        edit_posting(conn, posting, user, params)
    end
  end

  defp publish_draft(conn, posting, user, params) do
    with {:ok, organization} <- organization_for_update(params, posting, user),
         {:ok, published} <- Jobs.publish(posting, user, params, organization: organization) do
      ApiV2.send_json(conn, JobPostingDoc.api_show(published))
    else
      {:error, {:organization, reason}} -> organization_error(conn, reason)
      {:error, reason} -> publish_error(conn, reason)
    end
  end

  defp edit_posting(conn, posting, user, params) do
    with {:ok, organization} <- organization_for_update(params, posting, user),
         {:ok, updated} <- Jobs.update_posting(posting, user, params, organization: organization) do
      ApiV2.send_json(conn, JobPostingDoc.api_show(updated))
    else
      {:error, {:organization, reason}} -> organization_error(conn, reason)
      {:error, %Ecto.Changeset{} = changeset} -> Problem.validation_failed(conn, changeset)
    end
  end

  def close(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, posting} <- fetch_own_job(id, user),
         {:ok, reason} <- parse_close_reason(params["reason"]),
         true <- Jobs.effective_status(posting) in [:published, :expired] do
      {:ok, closed} = Jobs.close(posting, reason)
      ApiV2.send_json(conn, JobPostingDoc.api_show(closed))
    else
      :error ->
        Problem.not_found(conn)

      {:error, :bad_reason} ->
        Problem.send_problem(conn, 422, "Validation failed",
          detail: "reason must be \"filled\" or \"withdrawn\".",
          extra: %{errors: %{reason: ["is invalid"]}}
        )

      false ->
        Problem.send_problem(conn, 409, "Not closeable",
          detail: "Only a live posting can be closed.",
          extra: %{reason: :not_closeable}
        )
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case fetch_own_job(id, user) do
      {:ok, %JobPosting{status: :draft} = posting} ->
        {:ok, _deleted} = Jobs.delete_job_posting(posting)
        send_resp(conn, 204, "")

      {:ok, _published} ->
        Problem.send_problem(conn, 409, "Cannot discard",
          detail: "Only a draft can be discarded; close a published posting instead.",
          extra: %{reason: :not_draft}
        )

      :error ->
        Problem.not_found(conn)
    end
  end

  # ── Internals ──

  # A posting the viewer may read: the owner sees any state (their tooling needs
  # the final state of an expired/closed posting); everyone else only a currently
  # live, published one, mirroring the public detail page's visibility gate.
  defp fetch_readable_job(id, viewer) do
    fetch_job(id, fn posting ->
      Jobs.owner?(posting, viewer) or
        (Jobs.visible_to?(posting, viewer) and Jobs.effective_status(posting) == :published)
    end)
  end

  defp fetch_own_job(id, user), do: fetch_job(id, &Jobs.owner?(&1, user))

  defp fetch_job(id, allow?) do
    with uuid when is_binary(uuid) <- UUIDv7.cast_or_nil(id),
         %JobPosting{} = posting <- Jobs.get_job_posting(uuid),
         true <- allow?.(posting) do
      {:ok, Jobs.preload_for_show(posting)}
    else
      _missing_or_hidden -> :error
    end
  end

  # `organization` in the body attributes the posting to a verified organization
  # page — only a role holder may, otherwise a clean "attribution denied". A
  # missing key on an update keeps the current attribution.
  defp resolve_organization(nil, _user), do: {:ok, nil}
  defp resolve_organization("", _user), do: {:ok, nil}

  defp resolve_organization(slug, user) when is_binary(slug) do
    case Organizations.get_organization_by_slug(slug) do
      nil ->
        {:error, :unknown_organization}

      org ->
        if Organizations.can_manage?(org, user),
          do: {:ok, org},
          else: {:error, :attribution_denied}
    end
  end

  defp resolve_organization(_other, _user), do: {:ok, nil}

  defp organization_for_update(params, posting, user) do
    if Map.has_key?(params, "organization") do
      case resolve_organization(params["organization"], user) do
        {:ok, org} -> {:ok, org}
        {:error, reason} -> {:error, {:organization, reason}}
      end
    else
      {:ok, posting.organization}
    end
  end

  defp organization_error(conn, :attribution_denied) do
    Problem.send_problem(conn, 403, "Attribution denied",
      detail: "You need a role at that organization to post on its behalf.",
      extra: %{reason: :attribution_denied}
    )
  end

  defp organization_error(conn, :unknown_organization) do
    Problem.send_problem(conn, 422, "Unknown organization",
      detail: "No verified organization has that slug.",
      extra: %{reason: :unknown_organization}
    )
  end

  defp publish_error(conn, %Ecto.Changeset{} = changeset),
    do: Problem.validation_failed(conn, changeset)

  defp publish_error(conn, :email_unconfirmed) do
    Problem.send_problem(conn, 403, "Email unconfirmed",
      detail: "Confirm your email address before publishing.",
      extra: %{reason: :email_unconfirmed}
    )
  end

  defp publish_error(conn, :account_too_new) do
    Problem.send_problem(conn, 403, "Account too new",
      detail: "Your account is not old enough to publish a job posting yet.",
      extra: %{reason: :account_too_new}
    )
  end

  defp publish_error(conn, reason) when reason in [:member_quota, :organization_quota] do
    Problem.send_problem(conn, 409, "Quota exceeded",
      detail: "You have reached the maximum number of concurrently published postings.",
      extra: %{reason: reason}
    )
  end

  defp parse_close_reason(reason) when reason in ["filled", "withdrawn"],
    do: {:ok, String.to_existing_atom(reason)}

  defp parse_close_reason(_other), do: {:error, :bad_reason}

  # The board's filter parser reads `workplace`/`employment`; accept the API's
  # documented `workplace_type`/`employment_type` names as aliases.
  defp normalize_filters(params) do
    params
    |> alias_param("workplace_type", "workplace")
    |> alias_param("employment_type", "employment")
  end

  defp alias_param(params, from, to) do
    case params[from] do
      nil -> params
      value -> Map.put_new(params, to, value)
    end
  end

  defp truthy(value), do: value in [true, "true", "1", "on", 1]
end
