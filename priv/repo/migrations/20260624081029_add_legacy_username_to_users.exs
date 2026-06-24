defmodule Vutuv.Repo.Migrations.AddLegacyUsernameToUsers do
  use Ecto.Migration

  def change do
    # Belt-and-suspenders: the member's original legacy handle (the dotted /
    # over-length import) is preserved on their own row before the
    # NormalizeLegacyUsernames backfill rewrites `username` to a valid one, so
    # the old handle is never lost. It doubles as the redirect source -
    # VutuvWeb.Plug.UserResolveSlug resolves an unknown slug through this column
    # and 301s to the member's current `username`. Null for accounts that were
    # already valid and never renamed.
    #
    # Additive nullable column -> backward compatible in one deploy. Unique so
    # an old handle maps to exactly one member (they were unique as usernames);
    # Postgres keeps the many NULLs distinct, so the already-valid members do
    # not collide on it.
    alter table(:users) do
      add(:legacy_username, :string)
    end

    create(unique_index(:users, [:legacy_username]))
  end
end
