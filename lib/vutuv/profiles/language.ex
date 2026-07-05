defmodule Vutuv.Profiles.Language do
  @moduledoc """
  A language a member speaks, with a proficiency level (issue #865).

  The language itself is stored as an ISO 639-1 code (see `Vutuv.Languages`);
  the proficiency is `"native"` or a CEFR level (`a1`..`c2`). Entries display
  in the member's own order (issue #894): they reorder the section like every
  other profile section, and the **first** entry is the language they prefer to
  be contacted in. Proficiency stays visible as the per-entry badge; it no
  longer drives the sort.
  """

  use VutuvWeb, :model

  # Proficiency levels in display order, highest first: a mother tongue, then
  # the CEFR scale (Common European Framework of Reference for Languages). The
  # order is the form's select order and the migration's backfill seed; it no
  # longer sorts the section (the member's `position` does — see `ordered/1`).
  @proficiencies ~w(native c2 c1 b2 b1 a2 a1)

  schema "languages" do
    field(:language_code, :string)
    field(:proficiency, :string)
    # The member's chosen display order; nil sorts last (legacy / mid-deploy
    # rows) until reordered. Set programmatically, never cast. See Vutuv.Ordering.
    field(:position, :integer)

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  @doc "The proficiency levels, highest first."
  def proficiencies, do: @proficiencies

  @doc "Languages in the member's chosen order (see `Vutuv.Ordering`)."
  def ordered(query \\ __MODULE__), do: Vutuv.Ordering.by_position(query)

  @doc """
  Creates a changeset based on the `model` and `params`.

  If no params are provided, an invalid changeset is returned with no
  validation performed.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [:language_code, :proficiency])
    |> validate_required([:language_code, :proficiency])
    |> validate_inclusion(:language_code, Vutuv.Languages.codes())
    |> validate_inclusion(:proficiency, @proficiencies)
    # Match the varchar(255) column so an oversized value is a changeset error,
    # never a raised Postgres 22001 (the codes are 2-3 chars, so this is purely
    # defensive, in the house style of the other profile schemas).
    |> validate_length(:language_code, max: 255)
    # One entry per language per member (the DB unique index backs this up).
    # Report it on :language_code, the field the form shows.
    |> unique_constraint(:language_code,
      name: :languages_user_id_language_code_index,
      message: "is already listed"
    )
  end

  # The language code is the stable, readable URL segment (unique per member),
  # so `/:slug/languages/en` addresses an entry rather than an opaque id.
  defimpl Phoenix.Param, for: __MODULE__ do
    def to_param(%{language_code: code}), do: code
  end
end
