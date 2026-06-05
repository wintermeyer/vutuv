defmodule Vutuv.Accounts.Email do
  @moduledoc false

  use VutuvWeb, :model
  import Vutuv.ChangesetHelpers, only: [downcase_value: 1]

  schema "emails" do
    field(:value, :string)
    field(:md5sum, :string)
    field(:public?, :boolean, default: true)
    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end

  @required_fields ~w(value public?)a
  @optional_fields ~w()a

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @required_fields ++ @optional_fields)
    |> validate_required([:value])
    |> downcase_value
    |> validate_format(:value, ~r/@/)
    |> unique_constraint(:value)
    |> fill_md5sum
  end

  # The address itself is an identity and may only be set through the
  # PIN-verified create/confirm flow, so editing is limited to the public? flag.
  def update_changeset(model, params \\ %{}) do
    cast(model, params, [:public?])
  end

  def fill_md5sum(changeset) do
    if value = get_change(changeset, :value) do
      md5sum =
        :crypto.hash(:md5, value)
        |> Base.encode16()
        |> String.downcase()

      put_change(changeset, :md5sum, md5sum)
    else
      changeset
    end
  end

  def can_delete?(id) do
    Vutuv.Repo.one(
      from(u in Vutuv.Accounts.Email, where: u.user_id == ^id, select: count("value"))
    ) > 1
  end
end
