defmodule Vutuv.Mutes.AccountMute do
  @moduledoc """
  One account a reader has silenced, and how far the silence reaches. Written
  and read through `Vutuv.Mutes`, never from user params directly: the target
  arrives as a struct the caller already loaded, so a member can only ever mute
  an account they were looking at.

  Exactly one of the three target columns is set, the same nullable-set shape
  the rest of the schema uses for "a member, a page, or an account out there"
  (issue #1336) — CHECK-enforced, so a row can never name two.

  `scope`:
    * `:all` — nothing this account writes reaches the reader's feed, whoever
      passes it on.
    * `:reposts` — only what they **pass on** is dropped; their own posts stay.
      This is the scope that names an account the reader follows: the complaint
      is not the account, it is the stream of somebody else's posts arriving
      through it.
  """

  use VutuvWeb, :model

  @scopes [:all, :reposts]

  schema "account_mutes" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:muted_user, Vutuv.Accounts.User)
    belongs_to(:muted_organization, Vutuv.Organizations.Organization)
    belongs_to(:muted_remote_account, Vutuv.Fediverse.RemoteAccount)
    field(:scope, Ecto.Enum, values: @scopes, default: :all)

    timestamps()
  end

  @doc "The scopes a mute can have (`:all`, `:reposts`)."
  def scopes, do: @scopes

  @doc """
  A mute of `target`, whose struct decides which column carries it.

  The target column is set here rather than cast, because it is never a
  parameter: `Vutuv.Mutes` hands over a record it loaded, and the only thing a
  member chooses is the scope.
  """
  def changeset(mute, target, scope) do
    mute
    |> cast(%{scope: scope}, [:scope])
    |> validate_required([:scope])
    |> put_target(target)
    |> unique_constraint([:user_id, :muted_user_id],
      name: :account_mutes_user_member_index
    )
    |> unique_constraint([:user_id, :muted_organization_id],
      name: :account_mutes_user_organization_index
    )
    |> unique_constraint([:user_id, :muted_remote_account_id],
      name: :account_mutes_user_remote_account_index
    )
    |> check_constraint(:muted_user_id,
      name: :no_self_mute,
      message: "You cannot mute yourself."
    )
  end

  defp put_target(changeset, %Vutuv.Accounts.User{id: id}),
    do: put_change(changeset, :muted_user_id, id)

  defp put_target(changeset, %Vutuv.Organizations.Organization{id: id}),
    do: put_change(changeset, :muted_organization_id, id)

  defp put_target(changeset, %Vutuv.Fediverse.RemoteAccount{id: id}),
    do: put_change(changeset, :muted_remote_account_id, id)
end
