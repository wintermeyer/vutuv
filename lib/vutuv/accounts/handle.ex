defmodule Vutuv.Accounts.Handle do
  @moduledoc """
  One row in the shared handle registry (issue #941): a single `@name` claimed
  in the URL-root namespace (`/:handle`), owned by exactly one member
  (`user_id`) XOR one company (`company_id`).

  The registry exists for **one** reason: its `UNIQUE(value)` index is the one
  place cross-table uniqueness is enforced, because Postgres cannot span a
  unique constraint across `users` and `companies`. Resolution does **not** read
  this table (the resolver reads `users.username` / `companies.username`
  directly); every handle write syncs its row here in the same transaction as
  the owner write, so a colliding claim loses on the unique index instead of
  racing. `Vutuv.Handles` owns the sync + a drift test keeps the owner columns
  and the registry in lock-step.
  """

  use VutuvWeb, :model

  alias Vutuv.Accounts.User
  alias Vutuv.Companies.Company

  schema "handles" do
    field(:value, :string)
    belongs_to(:user, User)
    belongs_to(:company, Company)

    timestamps()
  end

  @doc """
  Sets the row's handle `value` (already validated for grammar/length on the
  owner changeset). The caller sets the owner FK on the struct; this only moves
  `value` and carries the constraint mappings so a collision surfaces as a
  changeset error rather than a raised exception.
  """
  def changeset(handle, value) do
    handle
    |> change(value: value)
    |> validate_required(:value)
    |> unique_constraint(:value,
      name: :handles_value_index,
      message: "has already been taken"
    )
    |> unique_constraint(:user_id, name: :handles_user_id_index)
    |> unique_constraint(:company_id, name: :handles_company_id_index)
    |> check_constraint(:value,
      name: :handles_one_owner,
      message: "must belong to exactly one owner"
    )
  end
end
