defmodule Vutuv.JobPostings.JobPostingTag do
  @moduledoc false

  use VutuvWeb, :model
  import Ecto.Query

  schema "job_posting_tags" do
    field(:priority, :integer)

    belongs_to(:job_posting, Vutuv.JobPostings.JobPosting)
    belongs_to(:tag, Vutuv.Tags.Tag)

    timestamps()
  end

  @doc """
  Builds a changeset based on the `struct` and `params`.
  """
  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [:job_posting_id, :tag_id, :priority])
    |> validate_required([:priority])
    |> unique_constraint(:job_posting_id_tag_id)
    |> validate_max_tags()
  end

  defp validate_max_tags(changeset) do
    priority = get_field(changeset, :priority)
    id = get_field(changeset, :job_posting_id)

    if priority && id do
      # Single source of truth for the ceilings; see JobPosting.
      max = Vutuv.JobPostings.JobPosting.max_tags_for_priority(priority)

      if Vutuv.Repo.one(
           from(j in __MODULE__,
             where:
               j.job_posting_id == ^id and
                 j.priority == ^priority,
             select: count("*")
           )
         ) >= max do
        add_error(
          changeset,
          :priority,
          "You already have the maximum number of tags in this category"
        )
      else
        changeset
      end
    else
      changeset
    end
  end

  # Read the already-loaded :tag association when present; only hit the database
  # when it has not been preloaded. Mirrors `Vutuv.Tags.UserTag.tag/1` so callers
  # that preload the tag avoid a query per row while bare structs still resolve.
  @doc false
  def tag(%__MODULE__{tag: %Vutuv.Tags.Tag{} = tag}), do: tag
  def tag(%__MODULE__{} = job_posting_tag), do: Vutuv.Repo.preload(job_posting_tag, :tag).tag

  defimpl Phoenix.Param, for: Vutuv.JobPostings.JobPostingTag do
    def to_param(job_posting_tag) do
      Vutuv.JobPostings.JobPostingTag.tag(job_posting_tag).slug
    end
  end
end
