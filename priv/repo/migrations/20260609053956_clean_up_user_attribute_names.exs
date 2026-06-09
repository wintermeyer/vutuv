defmodule Vutuv.Repo.Migrations.CleanUpUserAttributeNames do
  use Ecto.Migration

  def change do
    # Disambiguate two near-synonym booleans and tidy three names. See the User
    # schema docs: `identity_verified?` is the admin ID check (was `verified`),
    # `activated?` is the email-PIN login confirmation (was `validated?`).
    rename(table(:users), :verified, to: :identity_verified?)
    rename(table(:users), :validated?, to: :activated?)
    rename(table(:users), :middlename, to: :middle_name)
    rename(table(:users), :administrator, to: :admin?)
  end
end
