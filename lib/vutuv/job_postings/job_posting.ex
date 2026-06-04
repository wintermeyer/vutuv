defmodule Vutuv.JobPostings.JobPosting do
  @moduledoc false

  use VutuvWeb, :model
  @derive {Phoenix.Param, key: :slug}

  alias Vutuv.JobPostings.JobPostingTag
  alias Vutuv.Tags.Tag

  schema "job_postings" do
    field(:title, :string)
    field(:description, :string)
    field(:location, :string)
    field(:prerequisites, :string)
    field(:slug, :string)
    field(:open_on, :date)
    field(:closed_on, :date)
    field(:company, :string)
    field(:min_salary, :integer)
    field(:max_salary, :integer)
    field(:currency, :string)
    field(:remote, :boolean)

    belongs_to(:user, Vutuv.Accounts.User)

    has_many(:job_posting_tags, JobPostingTag)
    has_many(:tags, through: [:job_posting_tags, :tag])

    timestamps()
  end

  @max_important_tags 3
  @max_optional_tags 7

  @doc """
  Builds a changeset based on the `struct` and `params`.
  """
  def changeset(struct, params \\ %{}) do
    struct
    # `user_id` is intentionally NOT cast: it is set programmatically via
    # `Ecto.build_assoc(user, :job_postings)` in the controller. Casting it
    # would let a recruiter smuggle `job_posting[user_id]` and attribute a
    # posting to another user. It stays required and is satisfied by the assoc.
    |> cast(params, [
      :title,
      :description,
      :location,
      :prerequisites,
      :slug,
      :open_on,
      :closed_on,
      :company,
      :min_salary,
      :max_salary,
      :currency,
      :remote
    ])
    |> gen_slug()
    |> validate_required([:user_id, :title, :slug])
    |> validate_length(:title, max: 40)
    |> validate_length(:description, max: 8192)
    |> validate_length(:prerequisites, max: 8192)
    |> validate_length(:location, max: 200)
    |> validate_length(:company, max: 80)
    |> validate_dates()
    |> put_tags(params)
  end

  defp gen_slug(changeset) do
    value = get_field(changeset, :title)

    slug =
      value
      |> Vutuv.SlugHelpers.gen_slug_unique(__MODULE__, :slug)

    put_change(changeset, :slug, slug)
  end

  defp validate_dates(changeset) do
    open = get_field(changeset, :open_on)
    closed = get_field(changeset, :closed_on)

    cond do
      is_nil(open) or is_nil(closed) -> changeset
      Date.compare(open, closed) == :lt -> changeset
      true -> add_error(changeset, :open_on, "Open date must be less than Closed date.")
    end
  end

  defp put_tags(
         changeset,
         %{"important_tags" => important_tags, "optional_tags" => optional_tags}
       ) do
    important = parse_tags(important_tags)
    optional = parse_tags(optional_tags)

    changeset
    |> validate_tag_uniqueness(important, optional)
    |> validate_important_tags(important)
    |> validate_optional_tags(optional)
    |> put_assocs(important, optional)
  end

  defp put_tags(changeset, _), do: changeset

  defp parse_tags(tags) do
    tag_list =
      tags
      |> String.split(",")

    for(tag <- tag_list) do
      String.trim(tag)
    end
  end

  defp validate_tag_uniqueness(changeset, important, optional) do
    tags = important ++ optional

    if Enum.count(tags) == Enum.count(Enum.uniq(tags)) do
      changeset
    else
      add_error(changeset, :job_posting_id_tag_id, "Tags must all be different")
    end
  end

  defp validate_important_tags(changeset, important) do
    if Enum.count(important) != @max_important_tags do
      add_error(
        changeset,
        :important_tags,
        "You must have #{@max_important_tags} important tags."
      )
    else
      changeset
    end
  end

  defp validate_optional_tags(changeset, optional) do
    if Enum.count(optional) > @max_optional_tags do
      add_error(
        changeset,
        :optional_tags,
        "You can have a maximum of #{@max_optional_tags} optional tags."
      )
    else
      changeset
    end
  end

  defp put_assocs(changeset, important, optional) do
    changeset
    |> put_assoc(
      :job_posting_tags,
      tag_changesets(important, 2) ++
        tag_changesets(optional, 1)
    )
  end

  defp tag_changesets(tags, priority) do
    for(tag <- tags) do
      %JobPostingTag{}
      |> JobPostingTag.changeset(%{priority: priority})
      |> Tag.create_or_link_tag(%{"value" => tag})
    end
  end

  def get_postings_for_user(user) do
    tags = Vutuv.Repo.preload(user, [:tags]).tags
    tag_ids = for tag <- tags, do: tag.id

    Vutuv.Repo.all(
      from(j in __MODULE__,
        left_join: jt in Vutuv.JobPostings.JobPostingTag,
        on: jt.job_posting_id == j.id,
        left_join: u in assoc(j, :user),
        left_join: s in assoc(u, :recruiter_subscriptions),
        where: jt.tag_id in ^tag_ids and s.paid == true,
        limit: 2,
        group_by: j.id,
        order_by: [
          desc: fragment("SUM(CASE WHEN ? = 2 THEN 1 ELSE 0 END)", jt.priority),
          desc: fragment("SUM(CASE WHEN ? = 1 THEN 1 ELSE 0 END)", jt.priority),
          desc: fragment("SUM(CASE WHEN ? = 0 THEN 1 ELSE 0 END)", jt.priority)
        ]
      )
    )
    |> ensure_jobs_returned()
  end

  defp ensure_jobs_returned([]) do
    Vutuv.Repo.all(
      from(j in __MODULE__,
        left_join: u in assoc(j, :user),
        left_join: s in assoc(u, :recruiter_subscriptions),
        where: s.paid == true,
        limit: 2
      )
    )
  end

  defp ensure_jobs_returned([head | []]) do
    [
      head
      | Vutuv.Repo.all(
          from(j in __MODULE__,
            left_join: u in assoc(j, :user),
            left_join: s in assoc(u, :recruiter_subscriptions),
            where: not (j.id == ^head.id) and s.paid == true,
            limit: 1
          )
        )
    ]
  end

  defp ensure_jobs_returned(jobs), do: jobs

  def get_important_tags(job) do
    Vutuv.Repo.all(
      from(t in Vutuv.Tags.Tag,
        left_join: j in assoc(t, :job_posting_tags),
        where: j.job_posting_id == ^job.id and j.priority == 2,
        limit: 3
      )
    )
  end
end
