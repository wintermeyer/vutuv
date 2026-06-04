defmodule Vutuv.Accounts.Slug do
  @moduledoc false

  use VutuvWeb, :model
  import Vutuv.ChangesetHelpers, only: [downcase_value: 1]
  alias Vutuv.Accounts.Slug

  schema "slugs" do
    field(:value, :string)
    field(:disabled, :boolean)
    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  @required_fields ~w(value)a
  @optional_fields ~w(user_id)a

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @required_fields ++ @optional_fields)
    |> downcase_value
    |> validate_format(:value, ~r/^[a-z]{1}[a-z0-9-.]*$/u)
    |> unique_constraint(:value)
    |> validate_length(:value, min: 3)
    |> trim_slug_to_32
    |> can_create_slug?(model)
  end

  # update_change/3 is a no-op when :value has no change, so no nil-check needed.
  defp trim_slug_to_32(changeset) do
    update_change(changeset, :value, &String.slice(&1, 0, 32))
  end

  defp can_create_slug?(changeset, model) do
    slug_count =
      if model.user_id != nil do
        Vutuv.Repo.one(from(s in Slug, where: s.user_id == ^model.user_id, select: count("*")))
      else
        0
      end

    if slug_count == 0 do
      changeset
    else
      now = NaiveDateTime.utc_now()

      last_slug_inserted_at =
        hd(
          Vutuv.Repo.all(
            from(s in Slug,
              where: s.user_id == ^model.user_id,
              order_by: [desc: s.inserted_at],
              select: s.inserted_at
            )
          )
        )

      # Keep FLOAT day semantics (divide seconds ourselves): the thresholds below
      # compare against 30/90 days, and NaiveDateTime.diff(_, :day) would truncate
      # and shift those thresholds at sub-day boundaries.
      last_slug_inserted_days = NaiveDateTime.diff(now, last_slug_inserted_at, :second) / 86_400

      user_inserted_at = Vutuv.Repo.get(Vutuv.Accounts.User, model.user_id).inserted_at
      user_age_days = NaiveDateTime.diff(now, user_inserted_at, :second) / 86_400

      cond do
        slug_count < 3 and user_age_days < 30 -> changeset
        slug_count >= 3 and last_slug_inserted_days > 90 -> changeset
        true -> add_error(changeset, :value, "Reached max new slugs in time period.")
      end
    end
  end
end
