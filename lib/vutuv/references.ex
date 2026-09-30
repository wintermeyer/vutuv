defmodule Vutuv.References do
  @moduledoc """
  Arbeitszeugnisse: a member's employment references, what they are attached
  to in the CV, and who may see them.

  The AI check that reads them lives next door in `Vutuv.References.Checks` —
  this module owns the documents themselves, so a Zeugnis remains a useful
  profile entry on an installation that runs no model at all.

  Every read here is scoped by owner or by public visibility. There is no
  "fetch by id" that skips both: an unpublished Zeugnis is one of the more
  sensitive things a member can store here.
  """

  import Ecto.Query, warn: false

  alias Vutuv.Accounts.User
  alias Vutuv.References.JobReference
  alias Vutuv.References.Link
  alias Vutuv.Repo

  # The countries whose Zeugnisrecht the analysis prompt actually covers. One
  # entry, because the prompt is one country's law: it decodes the German
  # grading convention against § 109 GewO and BAG case law. That is not a
  # rounding error away from its neighbours — Austrian law (§ 39 AngG) forbids
  # the coded grading this decodes, and Swiss practice (Art. 330a OR) has its
  # own vocabulary and case law — so running it on a foreign document would
  # produce a confident answer about the wrong legal system. Configurable so a
  # second, differently-sourced prompt can widen it later without a code change.
  @check_countries ~w(DE)

  @doc """
  The ISO 3166-1 alpha-2 countries the AI check covers.

  Everything else about a reference — uploading, attaching it to the CV,
  showing it — works in every country. Only the analysis is jurisdiction-bound.
  """
  def check_countries,
    do: Application.get_env(:vutuv, :reference_check_countries, @check_countries)

  @doc """
  Whether the AI check applies to this entry, i.e. whether it was issued in a
  country whose law the prompt covers.

  The UI asks this before offering the button, and says why when the answer is
  no. Silently hiding the option would read as a missing feature.
  """
  def check_supported?(%JobReference{country: country}), do: country in check_countries()

  @doc "The member's own references, newest issue date first."
  def list_job_references(%{id: user_id}) do
    JobReference
    |> where([r], r.user_id == ^user_id)
    |> order_by([r], desc_nulls_last: r.issued_on, desc: r.id)
    |> preload(:links)
    |> Repo.all()
  end

  @doc """
  The references a visitor may see on this member's profile: published, and
  with any attached document cleared by moderation.

  The moderation filter is in the query rather than in a later `Enum.filter`
  so a paginated read can never return a short page of already-filtered rows.
  """
  def public_job_references(%{id: user_id}) do
    JobReference.public_scope()
    |> where([r], r.user_id == ^user_id)
    |> preload(:links)
    |> Repo.all()
  end

  @doc "One of the member's own references, or nil."
  def get_job_reference(%{id: user_id}, id) when is_binary(id) do
    JobReference
    |> where([r], r.id == ^id and r.user_id == ^user_id)
    |> preload(:links)
    |> Repo.one()
  end

  @doc """
  One publicly visible reference by id, or nil — the public show page's read.
  """
  def get_public_job_reference(id) when is_binary(id) do
    JobReference
    |> JobReference.visible()
    |> where([r], r.id == ^id)
    |> preload([:links, :user])
    |> Repo.one()
  end

  @doc """
  Creates a reference owned by `user`.

  `user_id` is written from the struct, never from `attrs`, so a crafted
  request cannot file a Zeugnis onto another member's profile.

  Returns `{:duplicate, existing}` instead of inserting when the member
  already has an entry from the identical form: same title, employer, kind,
  text and file. That is what a second click on Save sends while a large
  upload is still on its way. The member's row is locked for the check and
  the insert, so two requests arriving together cannot both pass the check.
  A unique index would say the same more strongly, but it cannot be built
  over the duplicates this already left in production.
  """
  def create_job_reference(%{id: user_id}, attrs \\ %{}) do
    changeset =
      %JobReference{user_id: user_id}
      |> JobReference.changeset(attrs)
      |> JobReference.cast_document(attrs)
      |> JobReference.validate_content()

    if changeset.valid?,
      do: insert_unless_repeated(changeset, user_id),
      else: Repo.insert(changeset)
  end

  # NO KEY UPDATE is enough to queue a second create behind the first without
  # blocking unrelated reads of the member's row.
  defp insert_unless_repeated(changeset, user_id) do
    Repo.transact(fn ->
      Repo.one!(from(u in User, where: u.id == ^user_id, select: u.id, lock: "FOR NO KEY UPDATE"))

      case same_submission(changeset, user_id) do
        nil -> Repo.insert(changeset)
        existing -> {:error, {:duplicate, existing}}
      end
    end)
    |> case do
      {:error, {:duplicate, existing}} -> {:duplicate, existing}
      result -> result
    end
  end

  # The member's entry that the changeset would repeat, or nil. With a file,
  # the file is the content: the stored entry's text was read out of it after
  # the insert, so the repeat, which has none yet, would never match on text.
  # Every field is compared nil-aware: `x == ^nil` raises in Ecto.
  defp same_submission(changeset, user_id) do
    content =
      if Ecto.Changeset.get_field(changeset, :document_fingerprint),
        do: :document_fingerprint,
        else: :body

    [:title, :employer, :kind, content]
    |> Enum.reduce(
      from(r in JobReference, where: r.user_id == ^user_id),
      fn field, query ->
        case Ecto.Changeset.get_field(changeset, field) do
          nil -> where(query, [r], is_nil(field(r, ^field)))
          value -> where(query, [r], field(r, ^field) == ^value)
        end
      end
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc "Updates a reference the caller has already scoped to its owner."
  def update_job_reference(%JobReference{} = reference, attrs) do
    reference
    |> JobReference.changeset(attrs)
    |> JobReference.cast_document(attrs)
    |> JobReference.validate_content()
    |> Repo.update()
  end

  @doc "A changeset for the form."
  def change_job_reference(%JobReference{} = reference, attrs \\ %{}) do
    JobReference.changeset(reference, attrs)
  end

  @doc """
  Deletes a reference. Links and checks cascade in the database; the stored
  files are removed by the caller (`Vutuv.JobReferenceDocument.delete/1`),
  because only it knows the paths.
  """
  def delete_job_reference(%JobReference{} = reference), do: Repo.delete(reference)

  @doc """
  Replaces the CV links of `reference` with `subjects`, a list of
  `{kind, id}` pairs as produced by `Vutuv.References.Link.subject/1`.

  Only the member's own CV entries are accepted: a pair naming somebody else's
  work experience is dropped rather than rejected, so a stale form (an entry
  deleted in another tab) still saves instead of erroring on something the
  member cannot see or fix.
  """
  def put_links(%JobReference{} = reference, subjects) when is_list(subjects) do
    owned = owned_subjects(reference.user_id, subjects)

    Repo.transaction(fn ->
      Repo.delete_all(from(l in Link, where: l.job_reference_id == ^reference.id))

      Enum.each(owned, fn {field, id} ->
        %Link{job_reference_id: reference.id}
        |> Link.changeset(%{field => id})
        |> Repo.insert!()
      end)

      Repo.preload(reference, :links, force: true)
    end)
  end

  # Keeps only the pairs whose CV entry really belongs to this member. One
  # query per kind, and only for the kinds actually submitted.
  defp owned_subjects(user_id, subjects) do
    subjects
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {kind, ids} ->
      kind
      |> owned_ids(user_id, Enum.uniq(ids))
      |> Enum.map(&{field_for(kind), &1})
    end)
  end

  defp owned_ids(:work_experience, user_id, ids),
    do: owned_ids_from(Vutuv.Profiles.WorkExperience, user_id, ids)

  defp owned_ids(:education, user_id, ids),
    do: owned_ids_from(Vutuv.Profiles.Education, user_id, ids)

  defp owned_ids(:qualification, user_id, ids),
    do: owned_ids_from(Vutuv.Profiles.Qualification, user_id, ids)

  defp owned_ids(_unknown, _user_id, _ids), do: []

  defp owned_ids_from(schema, user_id, ids) do
    schema
    |> where([e], e.user_id == ^user_id and e.id in ^ids)
    |> select([e], e.id)
    |> Repo.all()
  end

  defp field_for(:work_experience), do: :work_experience_id
  defp field_for(:education), do: :education_id
  defp field_for(:qualification), do: :qualification_id

  @doc """
  The publicly visible references backing one CV entry, for the profile.

  `kind` is `:work_experience`, `:education` or `:qualification`.
  """
  def public_references_for(kind, subject_id) when is_binary(subject_id) do
    field = field_for(kind)

    JobReference
    |> JobReference.visible()
    |> join(:inner, [r], l in Link, on: l.job_reference_id == r.id)
    |> where([r, l], field(l, ^field) == ^subject_id)
    |> order_by([r], desc_nulls_last: r.issued_on, desc: r.id)
    |> Repo.all()
  end
end
