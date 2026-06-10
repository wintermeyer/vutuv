defmodule Vutuv.Moderation.Strike do
  @moduledoc false

  use VutuvWeb, :model

  @roles ~w(owner reporter)

  schema "moderation_strikes" do
    field(:role, :string)
    field(:level, :integer)
    field(:reason, :string)
    field(:expires_at, :naive_datetime)

    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:case, Vutuv.Moderation.Case)
    belongs_to(:issued_by, Vutuv.Accounts.User)

    timestamps()
  end

  def where_user(user_id), do: from(s in __MODULE__, where: s.user_id == ^user_id)

  def changeset(strike, params \\ %{}) do
    strike
    |> cast(params, [:role, :level, :reason, :expires_at])
    |> validate_required([:role, :level, :expires_at])
    |> validate_inclusion(:role, @roles)
  end
end
