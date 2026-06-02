defmodule Vutuv.Accounts.Slug do
  @moduledoc false

  use VutuvWeb, :model
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

  defp downcase_value(changeset), do: Vutuv.ChangesetHelpers.downcase_value(changeset)

  defp trim_slug_to_32(changeset) do
    get_change(changeset, :value)
    |> case do
      nil -> changeset
      _value -> update_change(changeset, :value, &slice_32/1)
    end
  end

  defp slice_32(string) do
    String.slice(string, 0, 32)
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
      last_slug_inserted_days =
        (:calendar.datetime_to_gregorian_seconds(:calendar.universal_time()) -
           :calendar.datetime_to_gregorian_seconds(
             NaiveDateTime.to_erl(
               hd(
                 Vutuv.Repo.all(
                   from(s in Slug,
                     where: s.user_id == ^model.user_id,
                     order_by: [desc: s.inserted_at],
                     select: s.inserted_at
                   )
                 )
               )
             )
           )) / 86_400

      user_age_days =
        (:calendar.datetime_to_gregorian_seconds(:calendar.universal_time()) -
           :calendar.datetime_to_gregorian_seconds(
             NaiveDateTime.to_erl(Vutuv.Repo.get(Vutuv.Accounts.User, model.user_id).inserted_at)
           )) / 86_400

      cond do
        slug_count < 3 and user_age_days < 30 -> changeset
        slug_count >= 3 and last_slug_inserted_days > 90 -> changeset
        true -> add_error(changeset, :value, "Reached max new slugs in time period.")
      end
    end
  end
end
