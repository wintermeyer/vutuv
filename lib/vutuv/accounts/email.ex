defmodule Vutuv.Accounts.Email do
  @moduledoc false

  use VutuvWeb, :model
  import Vutuv.ChangesetHelpers, only: [downcase_value: 1]

  schema "emails" do
    field(:value, :string)
    field(:md5sum, :string)
    # Privacy by default (GDPR Art. 25): an address is only shown to others
    # after the owner explicitly opts in (sign-up checkbox / email settings).
    field(:public?, :boolean, default: false)
    # A Work/Personal/Other label, mirroring PhoneNumber.number_type. Defaults
    # to "Other" (the unspecified bucket the registration/backfill assign).
    field(:email_type, :string, default: "Other")
    # Set by a failure DSN (Vutuv.Notifications.Bounces), cleared by a
    # successful login PIN through the address. Never cast from params.
    field(:undeliverable_at, :naive_datetime)
    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end

  @email_types ~w(Work Personal Other)

  @doc "The allowed `email_type` values, in the order the forms list them."
  def email_types, do: @email_types

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [:value, :public?, :email_type])
    |> validate_required([:value, :email_type])
    |> validate_inclusion(:email_type, @email_types)
    |> downcase_value
    |> validate_format(:value, ~r/@/)
    |> unique_constraint(:value)
    |> fill_md5sum
  end

  # The address itself is an identity and may only be set through the
  # PIN-verified create/confirm flow, so editing is limited to the public?
  # flag and the Work/Personal/Other label (both pure metadata).
  def update_changeset(model, params \\ %{}) do
    model
    |> cast(params, [:public?, :email_type])
    |> validate_inclusion(:email_type, @email_types)
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
